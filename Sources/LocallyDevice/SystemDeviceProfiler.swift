import Foundation
import LocallyCore

#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif

/// Reads real device characteristics via ProcessInfo / FileManager.
/// Apple-only probes (UIKit battery, Metal, os_proc_available_memory) are
/// compiled under `#if` and have honest Linux fallbacks.
public struct SystemDeviceProfiler: DeviceProfiler {
    public init() {}

    public func profile() async -> DeviceProfile {
        let processInfo = ProcessInfo.processInfo
        let physical = processInfo.physicalMemory
        let available = availableMemoryEstimate()
        let osProc = osProcAvailableMemory()

        let (free, total) = storageCapacity()
        let budget = MemoryBudget.safeAIBudget(
            physicalMemory: physical,
            availableEstimate: available,
            osProcAvailable: osProc
        )

        // UIDevice is @MainActor on iOS; read battery there.
        let battery = await batterySnapshot()

        return DeviceProfile(
            modelIdentifier: modelIdentifier(),
            osVersion: osVersionString(),
            physicalMemory: physical,
            availableMemoryEstimate: available,
            metalAvailable: metalAvailable(),
            recommendedMaxWorkingSet: budget,
            freeStorage: free,
            totalStorage: total,
            batteryLevel: battery.level,
            batteryState: battery.state,
            lowPowerMode: lowPowerModeEnabled(processInfo),
            thermalState: currentThermalState(processInfo),
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            neuralEngineAvailable: neuralEngineAvailable(),
            neuralEngineKnown: neuralEngineKnown()
        )
    }

    private func modelIdentifier() -> String {
        #if os(Linux)
        return "linux-\(machineArch())"
        #else
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        return mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(String(UnicodeScalar(UInt8(bitPattern: value))))
        }
        #endif
    }

    private func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        return mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(String(UnicodeScalar(UInt8(bitPattern: value))))
        }
    }

    private func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func availableMemoryEstimate() -> UInt64 {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if let osProc = osProcAvailableMemory(), osProc > 0 {
            return osProc
        }
        #endif
        // Fallback: report half of physical as a conservative estimate.
        return ProcessInfo.processInfo.physicalMemory / 2
    }

    private func osProcAvailableMemory() -> UInt64? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // os_proc_available_memory() is declared in <os/proc.h>, available on
        // iOS 13+. Linked dynamically to keep the SDK surface minimal.
        typealias ProcFunc = @convention(c) () -> UInt64
        guard let handle = dlopen(nil, RTLD_LAZY),
              let sym = dlsym(handle, "os_proc_available_memory") else { return nil }
        let fn = unsafeBitCast(sym, to: ProcFunc.self)
        return fn()
        #else
        return nil
        #endif
    }

    private func metalAvailable() -> Bool {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    /// UIDevice is @MainActor; bundle both battery reads behind one hop.
    /// `nil` level / `.unknown` state off Apple platforms.
    private func batterySnapshot() async -> (level: Float?, state: DeviceProfile.BatteryState) {
        #if canImport(UIKit) && os(iOS)
        return await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let rawLevel = device.batteryLevel
            let level: Float? = rawLevel >= 0 ? rawLevel : nil
            let state: DeviceProfile.BatteryState
            switch device.batteryState {
            case .unplugged: state = .unplugged
            case .charging: state = .charging
            case .full: state = .full
            default: state = .unknown
            }
            return (level, state)
        }
        #else
        return (nil, .unknown)
        #endif
    }

    private func lowPowerModeEnabled(_ processInfo: ProcessInfo) -> Bool {
        #if os(Linux)
        return false
        #else
        return processInfo.isLowPowerModeEnabled
        #endif
    }

    private func currentThermalState(_ processInfo: ProcessInfo) -> DeviceProfile.ThermalState {
        #if os(Linux)
        return .nominal
        #else
        switch processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
        #endif
    }

    private func neuralEngineKnown() -> Bool {
        #if os(iOS) || os(macOS) || os(visionOS)
        // Apple silicon iPhones (A11+) and all Macs on Apple silicon have an
        // ANE, but there is no public runtime query; treat presence as known
        // on Apple platforms and infer from model identifier.
        return true
        #else
        return false
        #endif
    }

    private func neuralEngineAvailable() -> Bool {
        guard neuralEngineKnown() else { return false }
        #if os(iOS) || os(visionOS)
        // A11 Bionic (iPhone 8/X) introduced the ANE. Model identifiers like
        // "iPhone10,x" and later have one. Rough but honest approximation.
        let id = modelIdentifier()
        if id.hasPrefix("iPhone") {
            let digits = id.dropFirst("iPhone".count).prefix(while: { $0.isNumber })
            if let major = Int(digits) { return major >= 10 }
        }
        if id.hasPrefix("iPad") { return true }
        return true // iOS 17 floor implies A12+ on supported phones
        #elseif os(macOS)
        return machineArch() == "arm64"
        #else
        return false
        #endif
    }

    private func storageCapacity() -> (free: Int64?, total: Int64?) {
        #if os(Linux)
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey,
            ])
            let free = values.volumeAvailableCapacity
            let total = values.volumeTotalCapacity
            return (free.map(Int64.init), total.map(Int64.init))
        } catch {
            return (nil, nil)
        }
        #else
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey,
            ])
            let free = values.volumeAvailableCapacityForImportantUsage
            let total = values.volumeTotalCapacity
            // `Int64.init` is ambiguous here (multiple overloads); spell out
            // the conversion so Xcode can pick exactly one.
            return (free.map { Int64($0) }, total.map { Int64($0) })
        } catch {
            return (nil, nil)
        }
        #endif
    }
}
