import SwiftUI
import LocallyCore
import LocallyDevice
import LocallyCompatibility

/// Evaluates CompatibilityReports on a cached device profile so the Models
/// UI never re-probes the device per row. Runtime availability reflects
/// what is actually linked into this build.
@MainActor
@Observable
final class CompatibilityProvider {
    static let shared = CompatibilityProvider()

    private(set) var profile: DeviceProfile?
    private(set) var benchmark: BenchmarkResult?

    private let profiler: DeviceProfiler = SystemDeviceProfiler()
    private var loadTask: Task<Void, Never>?

    /// Runtimes linked into this app build. MLX arrives when the package is
    /// integrated; the rest are in the package.
    private static func isAvailable(_ kind: RuntimeKind) -> Bool {
        switch kind {
        case .mlx:
            #if canImport(MLX)
            return true
            #else
            return false
            #endif
        case .gguf, .coreml, .decision, .vision, .diffusion, .audio, .video:
            return true
        }
    }

    private let engine = CompatibilityEngine(
        scorer: RuntimeScorer(isRuntimeAvailable: isAvailable)
    )

    private init() {}

    /// Idempotent: kicks off the device profile load once.
    func ensureLoaded() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let profile = await self?.profiler.profile()
            await MainActor.run { self?.profile = profile }
        }
    }

    /// Refresh the profile (e.g. after returning from background).
    func refresh() async {
        let profile = await profiler.profile()
        self.profile = profile
    }

    func report(for descriptor: ModelDescriptor,
                benchmarks: [InferenceMetadata] = []) -> CompatibilityReport? {
        guard let profile else { return nil }
        return engine.evaluate(descriptor: descriptor, device: profile,
                               benchmarks: benchmarks, deviceBenchmark: benchmark)
    }
}

/// The Compatibility block shared by the Add Model result card and the
/// Model Detail page. Renders nothing until the device profile has loaded.
struct CompatibilitySection: View {
    let report: CompatibilityReport

    @State private var showBreakdown = false

    var body: some View {
        Section {
            HStack(spacing: DS.Spacing.sm) {
                Text(String(localized: "compatibility.rating", table: "Compatibility"))
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Color.secondaryLabel)
                Spacer()
                ratingChip
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(String(localized: "compatibility.rating", table: "Compatibility")))
            .accessibilityValue(Text(ratingLabel))

            if let memory = report.memory {
                MetricRow(
                    title: String(localized: "compatibility.memory", table: "Compatibility"),
                    value: "\(Self.formatBytes(memory.low)) – \(Self.formatBytes(memory.high))"
                )
            }

            MetricRow(
                title: String(localized: "compatibility.speed", table: "Compatibility"),
                value: speedLabel
            )

            if let recommended = report.recommendedContext {
                MetricRow(
                    title: String(localized: "compatibility.context.recommended", table: "Compatibility"),
                    value: recommended.formatted(.number.grouping(.automatic))
                )
            }
            if let max = report.maxContext {
                MetricRow(
                    title: String(localized: "compatibility.context.max", table: "Compatibility"),
                    value: max.formatted(.number.grouping(.automatic))
                )
            }

            MetricRow(
                title: String(localized: "compatibility.thermal", table: "Compatibility"),
                value: thermalLabel,
                valueColor: thermalColor
            )

            if let runtime = report.recommendedRuntime {
                MetricRow(
                    title: String(localized: "compatibility.runtime", table: "Compatibility"),
                    value: runtime.rawValue
                )
            }

            if let memory = report.memory, !memory.components.isEmpty {
                DisclosureGroup(
                    String(localized: "compatibility.breakdown", table: "Compatibility"),
                    isExpanded: $showBreakdown
                ) {
                    ForEach(memory.components, id: \.name) { component in
                        MetricRow(
                            title: component.name,
                            value: component.low == component.high
                                ? Self.formatBytes(component.low)
                                : "\(Self.formatBytes(component.low)) – \(Self.formatBytes(component.high))"
                        )
                    }
                }
                .font(DS.Typography.body)
            }

            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.warning)
            }
            ForEach(report.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "xmark.octagon")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.bad)
            }
        } header: {
            Text(String(localized: "compatibility.section.title", table: "Compatibility"))
        }
    }

    private var ratingChip: some View {
        Text(ratingLabel)
            .font(DS.Typography.caption.weight(.semibold))
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .foregroundStyle(DS.Color.background)
            .background(ratingColor, in: Capsule())
    }

    private var ratingLabel: String {
        switch report.rating {
        case .excellent: return String(localized: "compatibility.rating.excellent", table: "Compatibility")
        case .good: return String(localized: "compatibility.rating.good", table: "Compatibility")
        case .usable: return String(localized: "compatibility.rating.usable", table: "Compatibility")
        case .risky: return String(localized: "compatibility.rating.risky", table: "Compatibility")
        case .unsupported: return String(localized: "compatibility.rating.unsupported", table: "Compatibility")
        }
    }

    private var ratingColor: Color {
        switch report.rating {
        case .excellent: return DS.Color.good
        case .good: return DS.Color.good.opacity(0.75)
        case .usable: return DS.Color.warning
        case .risky: return DS.Color.warning
        case .unsupported: return DS.Color.bad
        }
    }

    private var speedLabel: String {
        switch report.speed {
        case .measured(let low, let high):
            let range = Self.formatToks(low: low, high: high)
            return String(format: String(localized: "compatibility.speed.measured", table: "Compatibility"), range)
        case .estimated(let low, let high):
            let range = Self.formatToks(low: low, high: high)
            return String(format: String(localized: "compatibility.speed.estimated", table: "Compatibility"), range)
        case .unknown:
            return String(localized: "compatibility.speed.unknown", table: "Compatibility")
        }
    }

    private var thermalLabel: String {
        switch report.thermalLoad {
        case .low: return String(localized: "compatibility.thermal.low", table: "Compatibility")
        case .medium: return String(localized: "compatibility.thermal.medium", table: "Compatibility")
        case .high: return String(localized: "compatibility.thermal.high", table: "Compatibility")
        }
    }

    private var thermalColor: Color {
        switch report.thermalLoad {
        case .low: return DS.Color.good
        case .medium: return DS.Color.warning
        case .high: return DS.Color.bad
        }
    }

    static func formatToks(low: Double, high: Double) -> String {
        if abs(high - low) < 0.05 {
            return String(format: "%.1f tok/s", low)
        }
        return String(format: "%.1f–%.1f tok/s", low, high)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}
