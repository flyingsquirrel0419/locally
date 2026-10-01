import Foundation
import LocallyCore

/// Streams thermal-state changes. On Apple platforms this is driven by
/// NotificationCenter (`thermalStateDidChangeNotification`). On Linux there
/// is no thermal API, so the stream emits `.nominal` once and stays open —
/// polling-free by design.
public struct ThermalMonitor: Sendable {
    public init() {}

    public func states() -> AsyncStream<DeviceProfile.ThermalState> {
        #if os(Linux)
        return AsyncStream { continuation in
            continuation.yield(.nominal)
        }
        #else
        return AsyncStream { continuation in
            let center = NotificationCenter.default
            continuation.yield(map(ProcessInfo.processInfo.thermalState))
            let observer = center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(map(ProcessInfo.processInfo.thermalState))
            }
            // NSObjectProtocol isn't Sendable; box it so the @Sendable
            // onTermination closure can capture it. The box never escapes.
            let boxed = ObserverBox(observer)
            continuation.onTermination = { _ in
                center.removeObserver(boxed.value)
            }
        }
        #endif
    }

    #if !os(Linux)
    /// @unchecked Sendable wrapper for NSObjectProtocol observer tokens; the
    /// token is only ever read once in `onTermination`.
    private struct ObserverBox: @unchecked Sendable {
        let value: any NSObjectProtocol
        init(_ value: any NSObjectProtocol) { self.value = value }
    }

    private func map(_ state: ProcessInfo.ThermalState) -> DeviceProfile.ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
    #endif
}
