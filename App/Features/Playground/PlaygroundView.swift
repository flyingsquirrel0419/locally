import SwiftUI
import LocallyCore
import LocallyRuntime

/// Modality-aware playground container. Text models get the chat surface;
/// other modalities get an honest "not yet supported" state rather than a
/// fake preview.
struct PlaygroundView: View {
    /// The model under test. Until model selection ships (Week 7+), the
    /// playground opens empty; pass a descriptor to open a session.
    let model: ModelDescriptor?
    let router: RuntimeRouter
    let device: DeviceCapabilities

    init(model: ModelDescriptor? = nil,
         router: RuntimeRouter = RuntimeRouter(runtimes: [GGUFRuntime()]),
         device: DeviceCapabilities = DeviceCapabilities(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            metalAvailable: true,
            neuralEngineAvailable: true)) {
        self.model = model
        self.router = router
        self.device = device
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "tab.playground"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.modality {
            case .text:
                switch router.decide(for: model, on: device).rating {
                case .unsupported(let reason):
                    UnsupportedModelView(reason: reason)
                case .risky(let reason):
                    RiskyModelView(model: model, router: router, device: device, warning: reason)
                case .supported:
                    ChatView(model: model, router: router, device: device)
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
        } else {
            ContentUnavailableView(
                String(localized: "playground.empty.title", table: "Playground"),
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text(String(localized: "playground.empty.description", table: "Playground"))
            )
        }
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
    let router: RuntimeRouter
    let device: DeviceCapabilities
    let warning: String
    @State private var proceed = false

    var body: some View {
        if proceed {
            ChatView(model: model, router: router, device: device)
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
