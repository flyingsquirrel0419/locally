import Foundation
import LocallyCore
import LocallyDevice

#if canImport(UIKit)
import UIKit
#endif

/// App-wide resource policy: one observer for memory warnings, thermal
/// changes, and low-power mode. Feeds the pure `ResourcePolicy` decision
/// function (LocallyDevice) and applies the resulting actions through
/// injected handlers, so behavior is consistent across runtimes — the
/// runtimes themselves no longer register their own memory-warning
/// observers.
///
/// State lives on MainActor because SwiftUI views bind to it; the decision
/// itself is pure and tested in LocallyDeviceTests.
@Observable
@MainActor
final class ResourcePolicyObserver {
    static let shared = ResourcePolicyObserver()

    /// Latest thermal state (drives banners and the generation gate).
    private(set) var thermalState: DeviceProfile.ThermalState = .nominal
    private(set) var lowPowerMode: Bool = false
    private(set) var memoryWarningActive = false

    /// Current user-facing banner message, if any (highest priority reason
    /// from the last decision).
    private(set) var bannerMessage: String?

    /// What the app is currently doing; set by the registry/playgrounds.
    private(set) var activity: ResourcePolicy.Activity = .idle

    /// Throttle delay (ns) runtimes should insert between tokens right now;
    /// 0 when not throttled. Read by RuntimeRegistry's token pacing hook.
    private(set) var interTokenDelayNanoseconds: UInt64 = 0

    /// Frame-budget scale for video analysis (1.0 = full budget). Read by
    /// the video pipeline's pressure probe.
    private(set) var videoFrameBudgetScale: Double = 1.0

    /// Registered handlers for side effects the policy requests.
    struct Handlers {
        var stopGeneration: (@MainActor (String) -> Void)?
        var unloadIdleModel: (@MainActor (String) async -> Void)?
        var clearMediaCaches: (@MainActor () -> Void)?
        var clearAcceleratorCaches: (@MainActor () -> Void)?
    }
    var handlers = Handlers()

    private let policy = ResourcePolicy()
    private var observerTokens: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent start; called once from the app entry point.
    func start() {
        guard !started else { return }
        started = true
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // addObserver closures are @Sendable in Swift 6; hop to MainActor.
            MainActor.assumeIsolated {
                self?.handleMemoryWarning()
            }
        })
        observerTokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshThermal()
            }
        })
        observerTokens.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLowPower()
            }
        })
        refreshThermal()
        refreshLowPower()
        #endif
    }

    func stop() {
        let center = NotificationCenter.default
        for token in observerTokens { center.removeObserver(token) }
        observerTokens = []
        started = false
    }

    // MARK: - Activity tracking

    /// Called by RuntimeRegistry / playgrounds when heavy work starts/stops.
    func setActivity(_ activity: ResourcePolicy.Activity) {
        self.activity = activity
        applyDecision()
    }

    // MARK: - Gate

    /// Whether heavy inference may start right now; the reason is shown to
    /// the user when refused.
    func gateHeavyInference() -> (allowed: Bool, reason: String?) {
        policy.gate(thermal: thermalState,
                    memoryPressure: memoryWarningActive ? .warning : .normal)
    }

    // MARK: - Decision application

    private func handleMemoryWarning() {
        memoryWarningActive = true
        applyDecision()
        // The warning flag clears on the next thermal/low-power refresh or
        // after the stop completes — it is an event, not a state.
        memoryWarningActive = false
    }

    private func refreshThermal() {
        #if canImport(UIKit)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = .nominal
        case .fair: thermalState = .fair
        case .serious: thermalState = .serious
        case .critical: thermalState = .critical
        @unknown default: thermalState = .nominal
        }
        #endif
        applyDecision()
    }

    private func refreshLowPower() {
        #if canImport(UIKit)
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        #endif
        applyDecision()
    }

    private func applyDecision() {
        let actions = policy.decide(
            thermal: thermalState,
            lowPower: lowPowerMode,
            memoryPressure: memoryWarningActive ? .warning : .normal,
            activity: activity)

        var banner: String?
        interTokenDelayNanoseconds = 0
        videoFrameBudgetScale = 1.0

        for action in actions {
            switch action {
            case .stopGeneration(let reason):
                banner = banner ?? reason
                handlers.stopGeneration?(reason)
            case .unloadIdleModel(let reason):
                let handler = handlers.unloadIdleModel
                Task { await handler?(reason) }
            case .clearMediaCaches:
                handlers.clearMediaCaches?()
            case .clearAcceleratorCaches:
                handlers.clearAcceleratorCaches?()
            case .throttleGeneration(let reason):
                banner = banner ?? reason
                interTokenDelayNanoseconds = policy.throttleInterTokenDelayNanoseconds
            case .reduceVideoFrameBudget(let reason):
                banner = banner ?? reason
                videoFrameBudgetScale = 0.5
            case .warnImageGeneration(let reason):
                banner = banner ?? reason
            case .refuseHeavyInference(let reason):
                banner = banner ?? reason
            case .lowPowerBanner(let reason):
                banner = banner ?? reason
            }
        }
        bannerMessage = banner
    }
}
