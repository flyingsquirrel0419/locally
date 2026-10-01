import Foundation
import LocallyCore

/// Snapshot of device capabilities relevant to local AI inference.
public struct DeviceProfile: Codable, Sendable, Hashable {
    public enum ThermalState: String, Codable, Sendable, Hashable {
        case nominal, fair, serious, critical
    }

    public enum BatteryState: String, Codable, Sendable, Hashable {
        case unknown, unplugged, charging, full
    }

    /// Hardware model identifier, e.g. "iPhone16,2" or "arm64" on Linux.
    public var modelIdentifier: String
    public var osVersion: String
    /// Total physical RAM in bytes.
    public var physicalMemory: UInt64
    /// Best-effort estimate of currently free/usable memory in bytes.
    public var availableMemoryEstimate: UInt64
    public var metalAvailable: Bool
    /// Suggested working-set ceiling for AI workloads in bytes, when computable.
    public var recommendedMaxWorkingSet: UInt64?
    public var freeStorage: Int64?
    public var totalStorage: Int64?
    /// 0...1, when the platform exposes it.
    public var batteryLevel: Float?
    public var batteryState: BatteryState
    public var lowPowerMode: Bool
    public var thermalState: ThermalState
    public var processorCount: Int
    public var activeProcessorCount: Int
    public var neuralEngineAvailable: Bool
    /// False when the platform cannot report Neural Engine presence.
    public var neuralEngineKnown: Bool

    public init(
        modelIdentifier: String,
        osVersion: String,
        physicalMemory: UInt64,
        availableMemoryEstimate: UInt64,
        metalAvailable: Bool,
        recommendedMaxWorkingSet: UInt64? = nil,
        freeStorage: Int64? = nil,
        totalStorage: Int64? = nil,
        batteryLevel: Float? = nil,
        batteryState: BatteryState = .unknown,
        lowPowerMode: Bool = false,
        thermalState: ThermalState = .nominal,
        processorCount: Int,
        activeProcessorCount: Int,
        neuralEngineAvailable: Bool = false,
        neuralEngineKnown: Bool = false
    ) {
        self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion
        self.physicalMemory = physicalMemory
        self.availableMemoryEstimate = availableMemoryEstimate
        self.metalAvailable = metalAvailable
        self.recommendedMaxWorkingSet = recommendedMaxWorkingSet
        self.freeStorage = freeStorage
        self.totalStorage = totalStorage
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.neuralEngineAvailable = neuralEngineAvailable
        self.neuralEngineKnown = neuralEngineKnown
    }
}
