import SwiftUI
import LocallyStorage

struct DownloadsView: View {
    @State private var viewModel = DownloadsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.rows.isEmpty {
                    ContentUnavailableView(
                        String(localized: "empty.title", table: "Downloads"),
                        systemImage: "arrow.down.circle",
                        description: Text(String(localized: "empty.description", table: "Downloads"))
                    )
                } else {
                    List {
                        ForEach(viewModel.rows) { row in
                            DownloadRowView(row: row,
                                            onPause: { viewModel.pause(row.id) },
                                            onResume: { viewModel.resume(row.id) },
                                            onCancel: { viewModel.cancel(row.id) },
                                            onRetry: { viewModel.retry(row.id) })
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "tab.downloads"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(String(localized: "settings.wifiOnly", table: "Downloads"),
                               isOn: $viewModel.wifiOnly)
                        Toggle(String(localized: "settings.chargingOnly", table: "Downloads"),
                               isOn: $viewModel.chargingOnly)
                        Picker(String(localized: "settings.concurrency", table: "Downloads"),
                               selection: $viewModel.concurrency) {
                            ForEach([1, 2, 3, 4], id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(String(localized: "settings.menu", table: "Downloads"))
                }
            }
            .onAppear {
                if let manager = DownloadRuntime.shared.holder.manager {
                    viewModel.attach(manager: manager)
                }
            }
            .onDisappear { viewModel.detach() }
        }
    }
}

private struct DownloadRowView: View {
    let row: DownloadsViewModel.Row
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(row.repoID)
                    .font(DS.Typography.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                stateBadge
            }
            ProgressView(value: row.totalBytes > 0
                         ? Double(row.bytesDownloaded) / Double(row.totalBytes) : 0)
            HStack(spacing: DS.Spacing.sm) {
                Text("\(DownloadsViewModel.formatBytes(row.bytesDownloaded)) / \(DownloadsViewModel.formatBytes(row.totalBytes))")
                    .font(DS.Typography.caption.monospacedDigit())
                    .foregroundStyle(DS.Color.secondaryLabel)
                if let speed = row.bytesPerSecond {
                    Text("\(DownloadsViewModel.formatBytes(Int64(speed)))/s")
                        .font(DS.Typography.caption.monospacedDigit())
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
                Spacer()
                actionButtons
            }
            if let failure = row.failureMessage {
                Text(failure)
                    .font(DS.Typography.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (text, color): (String, Color) = {
            switch row.state {
            case .queued: return (String(localized: "state.queued", table: "Downloads"), .secondary)
            case .preparing, .downloading, .verifying:
                return (String(localized: "state.downloading", table: "Downloads"), .blue)
            case .paused: return (String(localized: "state.paused", table: "Downloads"), .orange)
            case .completed: return (String(localized: "state.completed", table: "Downloads"), .green)
            case .failed: return (String(localized: "state.failed", table: "Downloads"), .red)
            case .cancelled: return (String(localized: "state.cancelled", table: "Downloads"), .secondary)
            }
        }()
        Text(text)
            .font(DS.Typography.caption.weight(.medium))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch row.state {
        case .downloading, .preparing, .verifying, .queued:
            Button(action: onPause) {
                Image(systemName: "pause.fill")
            }
            .accessibilityLabel(String(localized: "action.pause", table: "Downloads"))
        case .paused:
            Button(action: onResume) {
                Image(systemName: "play.fill")
            }
            .accessibilityLabel(String(localized: "action.resume", table: "Downloads"))
        case .failed:
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(String(localized: "action.retry", table: "Downloads"))
        case .completed, .cancelled:
            EmptyView()
        }
        if row.state != .completed && row.state != .cancelled {
            Button(role: .destructive, action: onCancel) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(String(localized: "action.cancel", table: "Downloads"))
        }
    }
}
