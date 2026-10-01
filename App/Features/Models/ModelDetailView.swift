import SwiftUI
import LocallyCore
import LocallyStorage
import LocallyCompatibility

/// Full detail page for one installed model: info, runtime/context
/// overrides, benchmark history, run/delete actions.
struct ModelDetailView: View {
    let modelID: String
    let viewModel: ModelLibraryViewModel

    @Environment(ModelLibraryHolder.self) private var library
    @EnvironmentObject private var tabSelection: TabSelection
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    private var model: InstalledModel? {
        viewModel.models.first { $0.id == modelID }
    }

    var body: some View {
        Group {
            if let model {
                detail(model)
            } else {
                ContentUnavailableView(String(localized: "models.empty.title", table: "Models"),
                                       systemImage: "shippingbox")
            }
        }
        .navigationTitle(model?.descriptor.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detail(_ model: InstalledModel) -> some View {
        let supported = viewModel.availableRuntimes(for: model)
        Form {
            Section(String(localized: "models.detail.info", table: "Models")) {
                MetricRow(title: String(localized: "models.detail.revision", table: "Models"),
                          value: model.revision)
                MetricRow(title: String(localized: "models.detail.size", table: "Models"),
                          value: ModelLibraryViewModel.formatBytes(model.sizeOnDisk))
                MetricRow(title: String(localized: "models.detail.installed", table: "Models"),
                          value: model.installedAt.formatted(date: .abbreviated, time: .shortened))
                MetricRow(title: String(localized: "models.detail.lastUsed", table: "Models"),
                          value: model.lastUsedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
                                 ?? String(localized: "models.detail.never", table: "Models"))
                if let context = model.contextOverride ?? model.descriptor.contextLength {
                    MetricRow(title: String(localized: "models.detail.context", table: "Models"),
                              value: context.formatted(.number.grouping(.automatic)))
                }
                if let url = URL(string: "https://huggingface.co/\(model.repoID)") {
                    Link(String(localized: "models.detail.openRepo", table: "Models"),
                         destination: url)
                }
            }

            if let report = CompatibilityProvider.shared.report(
                for: model.descriptor, benchmarks: model.benchmarks
            ) {
                CompatibilitySection(report: report)
            }

            Section(String(localized: "models.detail.runtime", table: "Models")) {
                if supported.isEmpty {
                    Text(String(localized: "models.runtime.unsupported", table: "Models"))
                        .foregroundStyle(DS.Color.warning)
                } else {
                    Picker(String(localized: "models.runtime.picker", table: "Models"),
                           selection: runtimeBinding(model, supported: supported)) {
                        ForEach(supported, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                }
                if let maxContext = model.descriptor.contextLength {
                    Stepper(
                        "\(String(localized: "models.detail.context", table: "Models")): \((model.contextOverride ?? maxContext).formatted(.number.grouping(.automatic)))",
                        value: contextBinding(model, max: maxContext),
                        in: 512...maxContext,
                        step: 512
                    )
                }
            }

            Section(String(localized: "models.detail.benchmark", table: "Models")) {
                // No real runtime exists yet, so benchmarking cannot run;
                // the button is disabled with the reason visible.
                Button(String(localized: "models.detail.benchmark", table: "Models")) {}
                    .disabled(true)
                Text(String(localized: "models.detail.benchmark.unavailable", table: "Models"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
                if model.benchmarks.isEmpty {
                    Text(String(localized: "models.detail.benchmarks.empty", table: "Models"))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryLabel)
                } else {
                    ForEach(Array(model.benchmarks.enumerated()), id: \.offset) { _, sample in
                        benchmarkRow(sample)
                    }
                }
            }

            Section {
                Button(String(localized: "models.detail.run", table: "Models")) {
                    run(model)
                }
                .disabled(supported.isEmpty || model.hasMissingFiles)

                Button(String(localized: "models.delete.button", table: "Models"),
                       role: .destructive) {
                    showDeleteConfirm = true
                }
            }

            if let actionError {
                Section {
                    Text(actionError)
                        .foregroundStyle(DS.Color.bad)
                }
            }
        }
        .alert(String(localized: "models.delete.confirm.title", table: "Models"),
               isPresented: $showDeleteConfirm) {
            Button(String(localized: "models.delete.button", table: "Models"), role: .destructive) {
                delete(model)
            }
            Button(String(localized: "models.add.cancel", table: "HF"), role: .cancel) {}
        } message: {
            Text(String(localized: "models.delete.confirm.message", table: "Models"))
        }
        .task { CompatibilityProvider.shared.ensureLoaded() }
    }

    private func benchmarkRow(_ sample: InferenceMetadata) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let tps = sample.tokensPerSecond {
                MetricRow(title: String(localized: "models.detail.benchmark.tps", table: "Models"),
                          value: String(format: "%.1f", tps))
            }
            if let ttft = sample.ttft {
                MetricRow(title: String(localized: "models.detail.benchmark.ttft", table: "Models"),
                          value: String(format: "%.2f s", ttft))
            }
            if let load = sample.loadTime {
                MetricRow(title: String(localized: "models.detail.benchmark.load", table: "Models"),
                          value: String(format: "%.2f s", load))
            }
            if let memory = sample.peakMemoryBytes {
                MetricRow(title: String(localized: "models.detail.benchmark.memory", table: "Models"),
                          value: ModelLibraryViewModel.formatBytes(memory))
            }
        }
    }

    private func runtimeBinding(_ model: InstalledModel, supported: [RuntimeKind]) -> Binding<RuntimeKind> {
        Binding(
            get: { model.runtimeOverride ?? model.runtime ?? supported.first ?? .gguf },
            set: { newValue in
                Task {
                    try? await library.registry?.updateSettings(id: model.id, runtime: .some(newValue))
                    viewModel.refresh()
                }
            }
        )
    }

    private func contextBinding(_ model: InstalledModel, max: Int) -> Binding<Int> {
        Binding(
            get: { model.contextOverride ?? max },
            set: { newValue in
                Task {
                    try? await library.registry?.updateSettings(id: model.id, context: .some(newValue))
                    viewModel.refresh()
                }
            }
        )
    }

    private func run(_ model: InstalledModel) {
        Task {
            try? await library.registry?.markUsed(id: model.id)
            await MainActor.run {
                tabSelection.selection = .playground
            }
        }
    }

    private func delete(_ model: InstalledModel) {
        Task {
            do {
                try await library.registry?.delete(id: model.id)
                await MainActor.run {
                    viewModel.refresh()
                    dismiss()
                }
            } catch let error as ModelRegistry.RegistryError {
                await MainActor.run {
                    switch error {
                    case .modelLoaded:
                        actionError = String(localized: "models.detail.delete.loaded", table: "Models")
                    case .notFound:
                        actionError = String(localized: "models.error.generic", table: "Models")
                    }
                }
            } catch {
                await MainActor.run {
                    actionError = String(localized: "models.error.generic", table: "Models")
                }
            }
        }
    }
}
