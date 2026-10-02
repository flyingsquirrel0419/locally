import SwiftUI
import LocallyStorage

/// Settings → Diagnostics: recent download lifecycle events and failures
/// from DownloadManager's ring buffer. Details are LocallyError
/// technicalDetails — they never contain tokens or request headers.
struct DiagnosticsView: View {
    @State private var events: [DownloadDiagnosticsEvent] = []

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(
                    String(localized: "diagnostics.empty.title"),
                    systemImage: "checklist",
                    description: Text(String(localized: "diagnostics.empty.description"))
                )
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(event.detail)
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Color.label)
                        Text(event.timestamp, format: .dateTime)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryLabel)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "diagnostics.title"))
        .onAppear { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        // DownloadRuntime.holder is set during app init, before any view
        // appears; a nil manager simply shows the empty state.
        events = DownloadRuntime.shared.holder.manager?.recentDiagnostics() ?? []
    }
}
