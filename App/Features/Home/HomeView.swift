import SwiftUI
import LocallyCore
import LocallyDevice
import LocallyStorage

@Observable
@MainActor
final class HomeViewModel {
    var profile: DeviceProfile?
    var benchmark: BenchmarkResult?
    var index: AIPerformanceIndex?
    var isBenchmarking = false
    var thermalState: DeviceProfile.ThermalState = .nominal

    // Library + downloads summary
    var installedCount = 0
    var recentModels: [InstalledModel] = []
    var activeDownloadCount = 0

    private let profiler: DeviceProfiler = SystemDeviceProfiler()
    // Task is Sendable and Task.cancel() is thread-safe; plain nonisolated
    // lets deinit cancel without violating MainActor isolation.
    private nonisolated var thermalTask: Task<Void, Never>?
    private nonisolated var benchmarkTask: Task<Void, Never>?
    private nonisolated var summaryTask: Task<Void, Never>?

    func load() async {
        profile = await profiler.profile()
        startThermalMonitoring()
    }

    /// Poll the registry + download manager slowly; these counts change on
    /// the order of seconds at fastest.
    func startSummaryPolling(registry: ModelRegistry?, manager: DownloadManager?) {
        guard summaryTask == nil else { return }
        summaryTask = Task { [weak self] in
            while !Task.isCancelled {
                if let registry {
                    let models = registry.list()
                    let recent = registry.recentModels(limit: 3)
                    await MainActor.run {
                        self?.installedCount = models.count
                        self?.recentModels = recent
                    }
                }
                if let manager, let jobs = try? await manager.jobs() {
                    let active = jobs.filter { !$0.isFinished }.count
                    await MainActor.run { self?.activeDownloadCount = active }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
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
                // Feed the Models tab: speed ratings read this benchmark.
                CompatibilityProvider.shared.recordBenchmark(result)
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
        summaryTask?.cancel()
    }
}

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @Environment(ModelLibraryHolder.self) private var library
    @Environment(DownloadManagerHolder.self) private var downloads

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    scoreCard
                    benchmarkButton
                    libraryCard
                    deviceCard
                    statusCard
                }
                .padding(DS.Spacing.md)
            }
            .background(DS.Color.background)
            .navigationTitle(String(localized: "home.title"))
            .task {
                await viewModel.load()
                viewModel.startSummaryPolling(registry: library.registry,
                                              manager: downloads.manager)
            }
            .onChange(of: library.registry != nil) { _, _ in
                viewModel.startSummaryPolling(registry: library.registry,
                                              manager: downloads.manager)
            }
        }
    }

    private var libraryCard: some View {
        Card {
            VStack(spacing: DS.Spacing.sm) {
                Text(String(localized: "home.models.installed", table: "Models"))
                    .font(DS.Typography.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricRow(title: String(localized: "home.models.installed", table: "Models"),
                          value: "\(viewModel.installedCount)",
                          systemImage: "shippingbox")
                MetricRow(title: String(localized: "home.downloads.active", table: "Models"),
                          value: viewModel.activeDownloadCount == 0
                                 ? String(localized: "home.downloads.none", table: "Models")
                                 : "\(viewModel.activeDownloadCount)",
                          systemImage: "arrow.down.circle")
                if !viewModel.recentModels.isEmpty {
                    Text(String(localized: "home.models.recent", table: "Models"))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(viewModel.recentModels) { model in
                        MetricRow(title: model.descriptor.name,
                                  value: ModelLibraryViewModel.formatBytes(model.sizeOnDisk),
                                  systemImage: "clock")
                    }
                }
            }
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
