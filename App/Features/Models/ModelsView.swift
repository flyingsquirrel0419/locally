import SwiftUI
import LocallyCore
import LocallyStorage

/// Models tab: the installed model library. Search, sort, swipe-to-delete
/// with confirmation, and a storage summary.
struct ModelsView: View {
    @State private var viewModel = ModelLibraryViewModel()
    @State private var showAddModel = false
    @Environment(ModelLibraryHolder.self) private var library

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.models.isEmpty {
                    ContentUnavailableView(
                        String(localized: "models.empty.title", table: "Models"),
                        systemImage: "shippingbox",
                        description: Text(String(localized: "models.empty.description", table: "Models"))
                    )
                } else {
                    libraryList
                }
            }
            .navigationTitle(String(localized: "tab.models"))
            .searchable(text: $viewModel.search,
                        prompt: String(localized: "models.search.placeholder", table: "Models"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "models.add.button", table: "HF"),
                           systemImage: "plus") {
                        showAddModel = true
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Picker(String(localized: "models.sort.recent", table: "Models"),
                           selection: $viewModel.sort) {
                        Text(String(localized: "models.sort.recent", table: "Models"))
                            .tag(ModelLibraryViewModel.Sort.recent)
                        Text(String(localized: "models.sort.name", table: "Models"))
                            .tag(ModelLibraryViewModel.Sort.name)
                        Text(String(localized: "models.sort.size", table: "Models"))
                            .tag(ModelLibraryViewModel.Sort.size)
                    }
                }
            }
            .sheet(isPresented: $showAddModel) {
                AddModelSheet()
            }
            .alert(item: $viewModel.pendingDelete) { model in
                Alert(
                    title: Text(String(localized: "models.delete.confirm.title", table: "Models")),
                    message: Text(String(localized: "models.delete.confirm.message", table: "Models")),
                    primaryButton: .destructive(Text(String(localized: "models.delete.button", table: "Models"))) {
                        viewModel.deletePending()
                    },
                    secondaryButton: .cancel()
                )
            }
            .task {
                if let registry = library.registry {
                    viewModel.attach(registry: registry)
                }
            }
            .onChange(of: library.registry != nil) { _, _ in
                if let registry = library.registry {
                    viewModel.attach(registry: registry)
                }
            }
        }
    }

    private var libraryList: some View {
        List {
            if let report = viewModel.reconcileReport, !report.orphanDirectories.isEmpty {
                Section {
                    Label(String(localized: "models.orphans.title", table: "Models") +
                          ": \(report.orphanDirectories.count)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.Color.warning)
                    Text(String(localized: "models.orphans.message", table: "Models"))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
            }

            Section {
                ForEach(viewModel.filtered) { model in
                    NavigationLink {
                        ModelDetailView(modelID: model.id, viewModel: viewModel)
                    } label: {
                        ModelRow(model: model,
                                 availableRuntimes: viewModel.availableRuntimes(for: model))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.confirmDelete(model)
                        } label: {
                            Label(String(localized: "models.delete.button", table: "Models"),
                                  systemImage: "trash")
                        }
                    }
                }
            }

            if let storage = viewModel.storage {
                Section {
                    MetricRow(title: String(localized: "models.storage.models", table: "Models"),
                              value: ModelLibraryViewModel.formatBytes(storage.totalModelBytes))
                    MetricRow(title: String(localized: "models.storage.cache", table: "Models"),
                              value: ModelLibraryViewModel.formatBytes(storage.downloadCacheBytes))
                } header: {
                    Text(String(localized: "models.storage.title", table: "Models"))
                }
            }
        }
        .refreshable { viewModel.refresh() }
    }
}

private struct ModelRow: View {
    let model: InstalledModel
    let availableRuntimes: [RuntimeKind]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Text(model.descriptor.name)
                    .font(DS.Typography.headline)
                    .lineLimit(1)
                ForEach(model.formats, id: \.self) { format in
                    Text(format.rawValue.uppercased())
                        .font(DS.Typography.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.Color.secondaryLabel.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                if let scheme = model.quantization?.scheme {
                    Text(scheme)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
            }
            HStack(spacing: DS.Spacing.sm) {
                Text(ModelLibraryViewModel.formatBytes(model.sizeOnDisk))
                Text("·")
                Text(model.lastUsedAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
                     ?? String(localized: "models.detail.never", table: "Models"))
                Text("·")
                Text(availableRuntimes.first?.rawValue
                     ?? String(localized: "models.runtime.unsupported", table: "Models"))
            }
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Color.secondaryLabel)
            if model.hasMissingFiles {
                Label(String(localized: "models.missingFiles", table: "Models"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.bad)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }
}
