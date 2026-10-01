import Foundation
import LocallyCore

/// Produces a `DeviceProfile` for the current device.
public protocol DeviceProfiler: Sendable {
    func profile() async -> DeviceProfile
}

/// Computes the safe memory budget for AI workloads on this device.
///
/// Heuristic (see DECISIONS.md): an iOS app realistically keeps
/// ~50–65% of physical RAM as its usable working set before jetsam.
/// Devices with the `com.apple.developer.kernel.increased-memory-limit`
/// entitlement can exceed this. We take 55% of physical RAM as a baseline,
/// clamp to the current available estimate, and further clamp to
/// `os_proc_available_memory()` when that API exists.
public enum MemoryBudget {
    public static func safeAIBudget(
        physicalMemory: UInt64,
        availableEstimate: UInt64,
        osProcAvailable: UInt64? = nil
    ) -> UInt64 {
        let baseline = UInt64(Double(physicalMemory) * 0.55)
        var budget = min(baseline, availableEstimate)
        if let osProc = osProcAvailable, osProc > 0 {
            budget = min(budget, osProc)
        }
        return budget
    }
}
