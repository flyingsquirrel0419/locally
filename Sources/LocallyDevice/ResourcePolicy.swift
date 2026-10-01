import Foundation
import LocallyCore

/// Pure, platform-independent resource policy: given the device's thermal
/// state, low-power mode, memory pressure, and current activity, decide what
/// the app should do. The iOS observer shell lives in
/// `App/Infrastructure/ResourcePolicyObserver.swift`; this type is the
/// testable brain.
public struct ResourcePolicy: Sendable {

    /// What the device is currently doing that the policy may interrupt.
    public enum Activity: String, Sendable, Hashable, CaseIterable {
        case idle
        case textGeneration
        case imageGeneration
        case visionInference
        case videoAnalysis
        case downloading

        /// Heavy inference that a critical thermal state refuses and a
        /// memory warning interrupts.
        public var isHeavyInference: Bool {
            switch self {
            case .textGeneration, .imageGeneration, .visionInference, .videoAnalysis:
                return true
            case .idle, .downloading:
                return false
            }
        }
    }

    /// Memory pressure as the platform reports it. `.warning` maps to
    /// `UIApplication.didReceiveMemoryWarningNotification`.
    public enum MemoryPressure: String, Sendable, Hashable {
        case normal, warning
    }

    /// One action the app should take, in priority order. Each carries the
    /// user-facing reason so banners and alerts stay consistent.
    public enum Action: Sendable, Hashable {
        /// Cancel active generation and unload the loaded model.
        case stopGeneration(reason: String)
        /// Unload any loaded-but-idle model to free memory.
        case unloadIdleModel(reason: String)
        /// Clear image/frame caches (rendered frames, decoded images).
        case clearMediaCaches
        /// Clear accelerator caches (MLX Metal buffer cache).
        case clearAcceleratorCaches
        /// Insert a small inter-token delay while generating.
        case throttleGeneration(reason: String)
        /// Sample fewer video frames per analysis.
        case reduceVideoFrameBudget(reason: String)
        /// Warn that image generation will be slow or may fail.
        case warnImageGeneration(reason: String)
        /// Refuse to start heavy inference until conditions improve.
        case refuseHeavyInference(reason: String)
        /// Show a low-power-mode banner; callers should pick conservative
        /// defaults (fewer tokens, fewer frames).
        case lowPowerBanner(reason: String)
    }

    public init() {}

    /// Decide actions for the given conditions. Order: hard stops first,
    /// then resource frees, then soft degradations. A condition already
    /// handled by a stronger action doesn't repeat itself in weaker ones.
    public func decide(
        thermal: DeviceProfile.ThermalState,
        lowPower: Bool,
        memoryPressure: MemoryPressure,
        activity: Activity
    ) -> [Action] {
        var actions: [Action] = []

        // Memory warning: stop what's running, free everything we can.
        // (Critical thermal below adds its own stop only if this one didn't.)
        var stopRequested = false
        if memoryPressure == .warning {
            if activity != .idle && activity != .downloading {
                actions.append(.stopGeneration(
                    reason: "Stopped because the device is low on memory."))
                stopRequested = true
            }
            actions.append(.unloadIdleModel(
                reason: "Unloaded the model to free memory."))
            actions.append(.clearMediaCaches)
            actions.append(.clearAcceleratorCaches)
        }

        switch thermal {
        case .critical:
            if activity.isHeavyInference && !stopRequested {
                actions.append(.stopGeneration(
                    reason: "Stopped because the device is too hot."))
            }
            actions.append(.refuseHeavyInference(
                reason: "The device is too hot. Heavy inference is paused until it cools down."))
        case .serious:
            if activity == .textGeneration || activity == .visionInference
                || activity == .videoAnalysis {
                actions.append(.throttleGeneration(
                    reason: "The device is warm; generation is slowed to let it cool."))
            }
            actions.append(.reduceVideoFrameBudget(
                reason: "The device is warm; fewer video frames will be analyzed."))
            if activity == .imageGeneration || activity == .idle {
                actions.append(.warnImageGeneration(
                    reason: "The device is warm; image generation will be slower."))
            }
        case .nominal, .fair:
            break
        }

        if lowPower {
            actions.append(.lowPowerBanner(
                reason: "Low Power Mode is on; using conservative settings."))
        }

        return actions
    }

    /// Whether starting heavy inference is allowed right now. Callers check
    /// this before `load`/`run` and show the accompanying reason.
    public func gate(
        thermal: DeviceProfile.ThermalState,
        memoryPressure: MemoryPressure
    ) -> (allowed: Bool, reason: String?) {
        if thermal == .critical {
            return (false, "The device is too hot. Heavy inference is paused until it cools down.")
        }
        if memoryPressure == .warning {
            return (false, "The device is low on memory. Try again after other apps are closed.")
        }
        return (true, nil)
    }

    /// Inter-token delay for the throttle action, in nanoseconds. Applied by
    /// runtimes between tokens; deliberately runtime-agnostic.
    public var throttleInterTokenDelayNanoseconds: UInt64 { 40_000_000 } // 40 ms
}
