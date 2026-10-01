import SwiftUI
import LocallyCore
import LocallyRuntime
import LocallyStorage

/// Modality-aware playground container. The picker lists installed text
/// models from the ModelRegistry; the router picks the runtime, with a
/// per-model override taken from the model's settings. Non-text modalities
/// get an honest "not yet supported" state rather than a fake preview.
struct PlaygroundView: View {
    @Environment(ModelLibraryHolder.self) private var library
    @Environment(RuntimeRegistryHolder.self) private var runtimes
    @Environment(AppNavigation.self) private var navigation

    /// For text models the playground offers two modes: free chat, or the
    /// decision surface (the decision runtime wraps the same text backend).
    enum PlaygroundMode: String, CaseIterable, Identifiable {
        case chat, decision
        var id: String { rawValue }
    }

    @State private var selectedID: String?
    @State private var mode: PlaygroundMode = .chat
    @State private var selectionTask: Task<Void, Never>?

    init() {}

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "tab.playground"))
                .toolbar {
                    if !installedTextModels.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            modelPicker
                        }
                    }
                }
        }
        .onAppear {
            runtimes.registry?.refreshDevice()
            consumeNavigationRequest()
            reconcileSelection()
        }
        .onChange(of: navigation.playgroundModelID) { _, _ in
            consumeNavigationRequest()
        }
        .onDisappear {
            selectionTask?.cancel()
        }
    }

    // MARK: - Model list

    /// Installed models the playground can serve: text (chat or decision
    /// mode), decision-modality models, vision-language models, video
    /// understanding, and image-generation models. MLX and GGUF formats both
    /// welcome — routing decides which runtime serves the selection.
    private var installedTextModels: [InstalledModel] {
        guard let registry = library.registry else { return [] }
        return registry.list().filter { model in
            !model.hasMissingFiles
                && (model.descriptor.modality == .text
                    || model.descriptor.modality == .unknown
                    || model.descriptor.modality == .decision
                    || model.descriptor.modality == .visionLanguage
                    || model.descriptor.modality == .imageUnderstanding
                    || model.descriptor.modality == .videoUnderstanding
                    || model.descriptor.modality == .imageGeneration)
        }
    }

    private var selectedModel: InstalledModel? {
        guard let selectedID else { return nil }
        return installedTextModels.first { $0.id == selectedID }
    }

    private var modelPicker: some View {
        Picker(String(localized: "playground.picker.model", table: "Playground"),
               selection: Binding<String?>(
                get: { selectedID },
                set: { select(id: $0) })) {
            Text(String(localized: "playground.picker.none", table: "Playground"))
                .tag(String?.none)
            ForEach(installedTextModels) { model in
                Text(model.descriptor.name).tag(String?.some(model.id))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let model = selectedModel,
           let registry = runtimes.registry {
            session(for: model, registry: registry)
        } else {
            ContentUnavailableView(
                String(localized: "playground.empty.title", table: "Playground"),
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text(String(localized: "playground.empty.description",
                                         table: "Playground"))
            )
        }
    }

    /// One session view per model+runtime decision: id() forces a fresh
    /// view model when either changes, so stale sessions never leak.
    @ViewBuilder
    private func session(for model: InstalledModel,
                         registry: RuntimeRegistry) -> some View {
        let prepared = preparedDescriptor(for: model, registry: registry)
        let decision = registry.router.decide(for: prepared, on: registry.device)
        switch model.descriptor.modality {
        case .visionLanguage, .imageUnderstanding:
            visionSession(prepared: prepared, decision: decision, registry: registry,
                          id: model.id)
        case .videoUnderstanding:
            videoSession(prepared: prepared, decision: decision, registry: registry,
                         id: model.id)
        case .imageGeneration:
            imageGenerationSession(prepared: prepared, decision: decision,
                                   registry: registry, id: model.id)
        case .decision:
            decisionSession(prepared: prepared, decision: decision, registry: registry,
                            id: model.id)
        case .text, .unknown:
            VStack(spacing: 0) {
                Picker(String(localized: "playground.mode", table: "Playground"),
                       selection: $mode) {
                    Text(String(localized: "playground.mode.chat", table: "Playground"))
                        .tag(PlaygroundMode.chat)
                    Text(String(localized: "playground.mode.decision", table: "Playground"))
                        .tag(PlaygroundMode.decision)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xs)
                switch mode {
                case .chat:
                    chatSession(prepared: prepared, decision: decision, registry: registry,
                                id: model.id)
                case .decision:
                    decisionSession(prepared: prepared, decision: decision, registry: registry,
                                    id: "\(model.id)#decision")
                }
            }
        default:
            ContentUnavailableView(
                String(localized: "playground.unsupportedModality.title", table: "Playground"),
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text(String(
                    localized: "playground.unsupportedModality.description",
                    table: "Playground"))
            )
        }
    }

    /// Chat surface, gated on the router's rating for the model.
    @ViewBuilder
    private func chatSession(prepared: ModelDescriptor,
                             decision: RuntimeRouter.Decision,
                             registry: RuntimeRegistry, id: String) -> some View {
        switch decision.rating {
        case .unsupported(let reason):
            UnsupportedModelView(reason: reason)
        case .risky(let reason):
            RiskyModelView(model: prepared, registry: registry, warning: reason)
                .id(id)
        case .supported:
            ChatView(model: prepared, registry: registry)
                .id(id)
        }
    }

    /// Image-generation surface, gated on the router's rating for the model.
    @ViewBuilder
    private func imageGenerationSession(prepared: ModelDescriptor,
                                        decision: RuntimeRouter.Decision,
                                        registry: RuntimeRegistry, id: String) -> some View {
        switch decision.rating {
        case .unsupported(let reason):
            UnsupportedModelView(reason: reason)
        case .risky(let reason):
            RiskyImageGenerationView(model: prepared, registry: registry, warning: reason)
                .id(id)
        case .supported:
            ImageGenerationView(model: prepared, registry: registry)
                .id(id)
        }
    }

    /// Decision surface, gated on the same router rating as chat: the
    /// decision runtime wraps the router-chosen text backend, so an
    /// unsupported text runtime means an unsupported decision run.
    @ViewBuilder
    private func decisionSession(prepared: ModelDescriptor,
                                 decision: RuntimeRouter.Decision,
                                 registry: RuntimeRegistry, id: String) -> some View {
        switch decision.rating {
        case .unsupported(let reason):
            UnsupportedModelView(reason: reason)
        case .risky(let reason):
            RiskyDecisionModelView(model: prepared, registry: registry, warning: reason)
                .id(id)
        case .supported:
            DecisionPlaygroundView(model: prepared, router: registry.router,
                                   device: registry.device)
                .id(id)
        }
    }

    /// Vision surface, gated on the router's rating for the model.
    @ViewBuilder
    private func visionSession(prepared: ModelDescriptor,
                               decision: RuntimeRouter.Decision,
                               registry: RuntimeRegistry, id: String) -> some View {
        switch decision.rating {
        case .unsupported(let reason):
            UnsupportedModelView(reason: reason)
        case .risky(let reason):
            RiskyVisionModelView(model: prepared, registry: registry, warning: reason)
                .id(id)
        case .supported:
            VisionPlaygroundView(model: prepared, registry: registry)
                .id(id)
        }
    }

    /// Video understanding surface: frame sampling over the same VLM stack.
    @ViewBuilder
    private func videoSession(prepared: ModelDescriptor,
                              decision: RuntimeRouter.Decision,
                              registry: RuntimeRegistry, id: String) -> some View {
        switch decision.rating {
        case .unsupported(let reason):
            UnsupportedModelView(reason: reason)
        case .risky(let reason):
            RiskyVideoModelView(model: prepared, registry: registry, warning: reason)
                .id(id)
        case .supported:
            VideoPlaygroundView(model: prepared, registry: registry)
                .id(id)
        }
    }

    /// Descriptor handed to the runtime: install location injected (directory
    /// for MLX, file path for GGUF), runtime override from the model's
    /// settings applied so the router honors it.
    private func preparedDescriptor(for model: InstalledModel,
                                    registry: RuntimeRegistry) -> ModelDescriptor {
        var descriptor = model.descriptor
        let layout = FilesystemLayout.applicationSupport()
        let directory = layout.modelDirectory(repoID: model.repoID, revision: model.revision)
        descriptor.metadata["localDirectory"] = directory.path
        if descriptor.metadata["localPath"] == nil,
           let first = descriptor.requiredFiles.first,
           let fileURL = try? layout.installedFileURL(
            repoID: model.repoID, revision: model.revision, relativePath: first.path) {
            descriptor.metadata["localPath"] = fileURL.path
        }
        if let override = model.runtimeOverride,
           descriptor.supportedRuntimes.contains(override) {
            descriptor.supportedRuntimes.removeAll { $0 == override }
            descriptor.supportedRuntimes.insert(override, at: 0)
        }
        if let context = model.contextOverride {
            descriptor.contextLength = context
        }
        return descriptor
    }

    // MARK: - Selection

    private func select(id: String?) {
        selectedID = id
        selectionTask?.cancel()
        guard let id, let registry = runtimes.registry else { return }
        guard let model = installedTextModels.first(where: { $0.id == id }) else { return }
        let prepared = preparedDescriptor(for: model, registry: registry)
        // One large model at a time: selecting a new model releases the old.
        selectionTask = Task {
            try? await library.registry?.markUsed(id: id)
            try? await registry.load(model: prepared)
        }
    }

    /// "Run in Playground" from Model Detail lands here.
    private func consumeNavigationRequest() {
        guard let id = navigation.playgroundModelID else { return }
        navigation.playgroundModelID = nil
        select(id: id)
    }

    /// Drop the selection if the model disappeared (deleted elsewhere).
    private func reconcileSelection() {
        guard let selectedID,
              !installedTextModels.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = nil
    }
}

/// Shown when no runtime can run the model: the reason comes from the
/// router's compatibility rating, not a hardcoded message.
private struct UnsupportedModelView: View {
    let reason: String

    var body: some View {
        ContentUnavailableView(
            String(localized: "playground.unavailable.title", table: "Playground"),
            systemImage: "exclamationmark.triangle",
            description: Text(reason)
        )
    }
}

/// Shown when a runtime reports the model as risky: warns, then lets the
/// user try anyway.
private struct RiskyModelView: View {
    let model: ModelDescriptor
    let registry: RuntimeRegistry
    let warning: String
    @State private var proceed = false

    var body: some View {
        if proceed {
            ChatView(model: model, registry: registry)
        } else {
            ContentUnavailableView {
                Label(String(localized: "playground.risky.title", table: "Playground"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(warning)
            } actions: {
                Button(String(localized: "playground.risky.tryAnyway", table: "Playground")) {
                    proceed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Risky gate for image generation: warns (e.g. original-attention UNet on
/// iPhone), then lets the user try anyway.
private struct RiskyImageGenerationView: View {
    let model: ModelDescriptor
    let registry: RuntimeRegistry
    let warning: String
    @State private var proceed = false

    var body: some View {
        if proceed {
            ImageGenerationView(model: model, registry: registry)
        } else {
            ContentUnavailableView {
                Label(String(localized: "playground.risky.title", table: "Playground"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(warning)
            } actions: {
                Button(String(localized: "playground.risky.tryAnyway", table: "Playground")) {
                    proceed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Risky gate for the decision surface: same warning flow as chat, then the
/// decision playground.
private struct RiskyDecisionModelView: View {
    let model: ModelDescriptor
    let registry: RuntimeRegistry
    let warning: String
    @State private var proceed = false

    var body: some View {
        if proceed {
            DecisionPlaygroundView(model: model, router: registry.router,
                                   device: registry.device)
        } else {
            ContentUnavailableView {
                Label(String(localized: "playground.risky.title", table: "Playground"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(warning)
            } actions: {
                Button(String(localized: "playground.risky.tryAnyway", table: "Playground")) {
                    proceed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}


/// Risky gate for the vision surface: same warning flow as chat.
private struct RiskyVisionModelView: View {
    let model: ModelDescriptor
    let registry: RuntimeRegistry
    let warning: String
    @State private var proceed = false

    var body: some View {
        if proceed {
            VisionPlaygroundView(model: model, registry: registry)
        } else {
            ContentUnavailableView {
                Label(String(localized: "playground.risky.title", table: "Playground"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(warning)
            } actions: {
                Button(String(localized: "playground.risky.tryAnyway", table: "Playground")) {
                    proceed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Risky gate for the video understanding surface.
private struct RiskyVideoModelView: View {
    let model: ModelDescriptor
    let registry: RuntimeRegistry
    let warning: String
    @State private var proceed = false

    var body: some View {
        if proceed {
            VideoPlaygroundView(model: model, registry: registry)
        } else {
            ContentUnavailableView {
                Label(String(localized: "playground.risky.title", table: "Playground"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(warning)
            } actions: {
                Button(String(localized: "playground.risky.tryAnyway", table: "Playground")) {
                    proceed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
