import SwiftUI
import LocallyCore

/// "Add model" sheet: paste a repo id or HF link, analyze, and review the
/// resulting descriptor before any download decision.
struct AddModelSheet: View {
    @State private var viewModel = AddModelViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: "models.add.placeholder", table: "HF"),
                        text: $viewModel.input
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    Button(String(localized: "models.add.analyze", table: "HF")) {
                        viewModel.analyze()
                    }
                    .disabled(viewModel.input.isEmpty || viewModel.isAnalyzing)
                }

                if viewModel.isAnalyzing {
                    Section {
                        HStack(spacing: DS.Spacing.sm) {
                            ProgressView()
                            Text(String(localized: "models.add.analyzing", table: "HF"))
                                .foregroundStyle(DS.Color.secondaryLabel)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(DS.Color.bad)
                    }
                }

                if let descriptor = viewModel.result {
                    resultSections(descriptor)
                }
            }
            .navigationTitle(String(localized: "models.add.title", table: "HF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "models.add.cancel", table: "HF")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ d: ModelDescriptor) -> some View {
        Section(d.name) {
            MetricRow(
                title: String(localized: "models.result.type", table: "HF"),
                value: d.modality.rawValue
            )
            if let params = d.parameterCount {
                MetricRow(
                    title: String(localized: "models.result.parameters", table: "HF"),
                    value: Self.formatParameters(params)
                )
            }
            if let quant = d.quantization {
                MetricRow(
                    title: String(localized: "models.result.quantization", table: "HF"),
                    value: quant.scheme ?? "\(quant.bits)-bit"
                )
            }
            if let size = d.totalDownloadSize {
                MetricRow(
                    title: String(localized: "models.result.downloadSize", table: "HF"),
                    value: Self.formatBytes(size)
                )
            }
            if !d.formats.isEmpty {
                MetricRow(
                    title: String(localized: "models.result.formats", table: "HF"),
                    value: d.formats.map(\.rawValue).joined(separator: ", ")
                )
            }
            if let context = d.contextLength {
                MetricRow(
                    title: String(localized: "models.result.context", table: "HF"),
                    value: context.formatted(.number.grouping(.automatic))
                )
            }
            if d.metadata["requiresRemoteCode"] == "true" {
                Text(String(localized: "models.result.remoteCodeWarning", table: "HF"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        }

        if let weightMemory = d.estimatedWeightMemory {
            Section {
                MetricRow(
                    title: String(localized: "models.result.weightMemory", table: "HF"),
                    value: Self.formatBytes(weightMemory)
                )
            } footer: {
                Text(String(localized: "models.result.estimate.footer", table: "HF"))
            }
        }

        Section {
            ForEach(d.requiredFiles, id: \.path) { file in
                HStack {
                    Text(file.path)
                        .font(DS.Typography.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(Self.formatBytes(file.size))
                        .font(DS.Typography.caption.monospacedDigit())
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
            }
        } header: {
            Text(String(format: String(localized: "models.result.files", table: "HF"),
                        d.requiredFiles.count))
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    static func formatParameters(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        return String(format: "%.0fM", Double(count) / 1_000_000)
    }
}
