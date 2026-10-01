import SwiftUI
import LocallyCore
import LocallyDevice

@Observable
final class HomeViewModel {
    var profile: DeviceProfile?
    var benchmark: BenchmarkResult?
    var index: AIPerformanceIndex?
    var isBenchmarking = false
    var thermalState: DeviceProfile.ThermalState = .nominal

    private let profiler: DeviceProfiler = SystemDeviceProfiler()
    private var thermalTask: Task<Void, Never>?
    private var benchmarkTask: Task<Void, Never>?

    func load() async {
        profile = await profiler.profile()
        startThermalMonitoring()
    }

    func runBenchmark() {
        guard !isBenchmarking else { return }
        isBenchmarking = true
        benchmarkTask = Task {
            let result = await DeviceBenchmark().run()
            guard !Task.isCancelled else {
                await MainActor.run { isBenchmarking = false }
                return
            }
            await MainActor.run {
                benchmark = result
                if let physical = profile?.physicalMemory {
                    index = AIPerformanceIndex.compute(benchmark: result,
                                                       physicalMemory: physical)
                }
                isBenchmarking = false
            }
        }
    }

    private func startThermalMonitoring() {
        guard thermalTask == nil else { return }
        thermalTask = Task {
            for await state in ThermalMonitor().states() {
                guard !Task.isCancelled else { return }
                await MainActor.run { thermalState = state }
            }
        }
    }

    deinit {
        thermalTask?.cancel()
        benchmarkTask?.cancel()
    }
}

struct HomeView: View {
    @State private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    scoreCard
                    benchmarkButton
                    deviceCard
                    statusCard
                }
                .padding(DS.Spacing.md)
            }
            .background(DS.Color.background)
            .navigationTitle(String(localized: "home.title"))
            .task { await viewModel.load() }
        }
    }

    private var scoreCard: some View {
        Card {
            VStack(spacing: DS.Spacing.sm) {
                ScoreGauge(score: viewModel.index?.score)
                    .frame(width: 160, height: 160)
                Text(String(localized: "home.score.disclaimer"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var benchmarkButton: some View {
        Button {
            viewModel.runBenchmark()
        } label: {
            if viewModel.isBenchmarking {
                HStack(spacing: DS.Spacing.sm) {
                    ProgressView()
                    Text(String(localized: "home.benchmark.running"))
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(String(localized: "home.benchmark.run"))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isBenchmarking)
    }

    private var deviceCard: some View {
        Card {
            VStack(spacing: DS.Spacing.sm) {
                Text(String(localized: "home.device"))
                    .font(DS.Typography.headline)
                if let profile = viewModel.profile {
                    MetricRow(title: String(localized: "home.device.model"),
                              value: profile.modelIdentifier,
                              systemImage: "iphone")
                    MetricRow(title: String(localized: "home.device.os"),
                              value: "iOS \(profile.osVersion)",
                              systemImage: "apple.logo")
                    MetricRow(title: String(localized: "home.device.memory"),
                              value: formattedBytes(profile.physicalMemory),
                              systemImage: "memorychip")
                    MetricRow(title: String(localized: "home.device.budget"),
                              value: profile.recommendedMaxWorkingSet.map(formattedBytes)
                                     ?? String(localized: "common.unknown"),
                              systemImage: "gauge.medium")
                    MetricRow(title: String(localized: "home.device.cores"),
                              value: "\(profile.activeProcessorCount) / \(profile.processorCount)",
                              systemImage: "cpu")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(spacing: DS.Spacing.sm) {
                Text(String(localized: "home.status"))
                    .font(DS.Typography.headline)
                MetricRow(title: String(localized: "home.status.thermal"),
                          value: thermalLabel(viewModel.thermalState),
                          systemImage: "thermometer.medium",
                          valueColor: thermalColor(viewModel.thermalState))
                if let profile = viewModel.profile {
                    MetricRow(title: String(localized: "home.status.storage"),
                              value: storageLabel(profile),
                              systemImage: "internaldrive")
                    MetricRow(title: String(localized: "home.status.battery"),
                              value: batteryLabel(profile),
                              systemImage: "battery.75percent")
                    MetricRow(title: String(localized: "home.status.metal"),
                              value: profile.metalAvailable
                                     ? String(localized: "common.available")
                                     : String(localized: "common.unavailable"),
                              systemImage: "gpu")
                    MetricRow(title: String(localized: "home.status.ane"),
                              value: neuralEngineLabel(profile),
                              systemImage: "brain")
                }
            }
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func storageLabel(_ profile: DeviceProfile) -> String {
        guard let free = profile.freeStorage, let total = profile.totalStorage else {
            return String(localized: "common.unknown")
        }
        let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(f) / \(t)"
    }

    private func batteryLabel(_ profile: DeviceProfile) -> String {
        guard let level = profile.batteryLevel else {
            return String(localized: "common.unknown")
        }
        return "\(Int(level * 100))%"
    }

    private func neuralEngineLabel(_ profile: DeviceProfile) -> String {
        guard profile.neuralEngineKnown else {
            return String(localized: "common.unknown")
        }
        return profile.neuralEngineAvailable
            ? String(localized: "common.available")
            : String(localized: "common.unavailable")
    }

    private func thermalLabel(_ state: DeviceProfile.ThermalState) -> String {
        switch state {
        case .nominal: return String(localized: "thermal.nominal")
        case .fair: return String(localized: "thermal.fair")
        case .serious: return String(localized: "thermal.serious")
        case .critical: return String(localized: "thermal.critical")
        }
    }

    private func thermalColor(_ state: DeviceProfile.ThermalState) -> Color {
        switch state {
        case .nominal: return DS.Color.good
        case .fair: return DS.Color.warning
        case .serious, .critical: return DS.Color.bad
        }
    }
}
