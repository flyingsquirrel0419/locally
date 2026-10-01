import Foundation
import LocallyCore
import LocallyDevice
import LocallyRuntime
import LocallyStorage

#if canImport(MLXLLM) && canImport(UIKit)
import MLX
#endif

/// Builds and owns the app's runtimes: GGUF (llama.cpp, from the shared
/// package) and MLX (app target only, when the SPM packages are linked and
/// a Metal device exists). Enforces one loaded large model at a time —
/// loading a new model unloads the previous runtime.
@Observable
@MainActor
final class RuntimeRegistry {
    /// Registered runtimes, in router preference order.
    let runtimes: [any ModelCompatibleRuntime]
    /// Router used for all routing decisions in the app.
    let router: RuntimeRouter
    /// Current device capabilities snapshot; refreshed on appear.
    private(set) var device: DeviceCapabilities

    /// The runtime currently holding a loaded model, if any.
    private(set) var activeRuntime: (any ModelCompatibleRuntime)?
    /// repoID of the loaded model, so re-selecting the same model is cheap
    /// and delete-protection can consult it.
    private(set) var loadedRepoID: String?

    init(runtimes: [any ModelCompatibleRuntime]? = nil) {
        // Thermal pacing: every token-generating runtime gets the
        // policy-backed pacer so a "serious" thermal state slows decode
        // without the runtimes knowing about the observer.
        let pacer = PolicyGenerationPacer()
        let runtimes = runtimes ?? [GGUFRuntime(pacer: pacer), MLXRuntime(pacer: pacer),
                                    VLMRuntime(pacer: pacer), DiffusionRuntime(),
                                    ExperimentalVideoGenerationRuntime()]
        self.runtimes = runtimes
        self.router = RuntimeRouter(runtimes: runtimes)
        self.device = RuntimeRegistry.probeDevice()
        wireResourcePolicy()
    }

    /// The app-wide resource policy owns memory-warning/thermal/low-power
    /// handling; the registry supplies the side effects it requests.
    private func wireResourcePolicy() {
        let observer = ResourcePolicyObserver.shared
        observer.handlers.unloadIdleModel = { [weak self] _ in
            await self?.unloadActive()
        }
        observer.handlers.clearAcceleratorCaches = {
            #if canImport(MLXLLM) && canImport(UIKit)
            MLX.Memory.clearCache()
            #endif
        }
        // Stop-generation and media-cache clearing are handled by the
        // playgrounds, which own their generation tasks and decoded-image
        // state and observe ResourcePolicyObserver.shared directly.
    }

    /// Token pacing hook for throttled generation: callers await this
    /// between tokens when the policy is throttling. No-op otherwise.
    func paceTokenIfThrottled() async {
        let delay = ResourcePolicyObserver.shared.interTokenDelayNanoseconds
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    /// Gate checked before loading a model for heavy inference.
    func heavyInferenceGate() -> (allowed: Bool, reason: String?) {
        ResourcePolicyObserver.shared.gateHeavyInference()
    }

    static func probeDevice() -> DeviceCapabilities {
        var metal = false
        #if canImport(Metal)
        metal = makeMetalDevice()
        #endif
        return DeviceCapabilities(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            metalAvailable: metal,
            neuralEngineAvailable: true)
    }

    func refreshDevice() {
        device = RuntimeRegistry.probeDevice()
    }

    /// Route a descriptor to a runtime, load it, and make it active. Any
    /// previously loaded model is unloaded first — one large model at a time.
    @discardableResult
    func load(model: ModelDescriptor) async throws -> any ModelCompatibleRuntime {
        guard let runtime = router.runtime(for: model, on: device) else {
            let reason = router.decide(for: model, on: device).reason
            throw LocallyError.runtimeUnavailable(
                userMessage: "No runtime on this device can run \(model.name).",
                technicalDetail: reason)
        }
        // MLX loads a directory (whole install), GGUF a single file; identity
        // is repoID because the registry only holds one model at a time and
        // the registry key must survive revision churn of the same download.
        if let active = activeRuntime, loadedRepoID != model.repoID {
            await active.unload()
            activeRuntime = nil
            loadedRepoID = nil
        }
        // Load-time memory refusal: when the analyzer produced a weight
        // estimate, refuse loads that exceed the device's safe AI budget
        // rather than letting the load die deep inside the runtime.
        let budget = MemoryBudget.safeAIBudget(
            physicalMemory: device.physicalMemory,
            availableEstimate: device.physicalMemory)
        if let estimate = model.estimatedWeightMemory, estimate > 0,
           estimate > Int64(budget) {
            let needed = Self.formatGB(estimate)
            let available = Self.formatGB(Int64(budget))
            throw LocallyError.insufficientMemory(
                userMessage: "Not enough memory: needs ~\(needed) GB, your device can safely provide ~\(available) GB.",
                technicalDetail: "estimatedWeightMemory=\(estimate) budget=\(budget)")
        }
        try await runtime.load(model)
        activeRuntime = runtime
        loadedRepoID = model.repoID
        return runtime
    }

    /// Unload whatever is loaded, if anything.
    func unloadActive() async {
        await activeRuntime?.unload()
        activeRuntime = nil
        loadedRepoID = nil
    }

    /// Availability predicate per runtime kind for the model settings UI:
    /// GGUF iff llama.cpp is linked, MLX iff MLXLLM is linked and a Metal
    /// device exists (simulator has no real GPU — reported honestly).
    func availability(for kind: RuntimeKind) -> RuntimeAvailability {
        switch kind {
        case .gguf:
            return GGUFRuntime.isLlamaLinked
                ? .available
                : .unavailable(reason: "llama.cpp is not linked into this build")
        case .mlx:
            guard MLXRuntime.isLibraryLinked else {
                return .unavailable(reason: "MLX libraries are not linked into this build")
            }
            return device.metalAvailable
                ? .available
                : .unavailable(reason: "MLX requires a Metal device; unavailable on Simulator")
        case .vision:
            guard VLMRuntime.isLibraryLinked else {
                return .unavailable(reason: "MLXVLM libraries are not linked into this build")
            }
            return device.metalAvailable
                ? .available
                : .unavailable(reason: "MLXVLM requires a Metal device; unavailable on Simulator")
        case .video:
            // Video generation has no real on-device backend yet.
            return .unavailable(reason: ExperimentalVideoGenerationRuntime.unavailableReason)
        default:
            return runtimes.contains { $0.kind == kind } ? .available
                : .unavailable(reason: "runtime not registered")
        }
    }

    /// Whole-or-tenth GB formatting for the memory refusal message.
    static func formatGB(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 10 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    enum RuntimeAvailability: Sendable, Hashable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
    }

    /// The app's runtime kind choices, in the order shown in pickers.
    static let selectableKinds: [RuntimeKind] = [.gguf, .mlx]
}

#if canImport(Metal)
import Metal

private func makeMetalDevice() -> Bool {
    MTLCreateSystemDefaultDevice() != nil
}
#endif

/// Environment-injectable holder so SwiftUI views reach the shared registry
/// without a singleton at the call site.
@Observable
final class RuntimeRegistryHolder {
    var registry: RuntimeRegistry?

    init(registry: RuntimeRegistry? = nil) {
        self.registry = registry
    }
}
