import SwiftUI
import LocallyStorage
import UIKit
import CoreTransferable

/// Settings → Diagnostics: recent download lifecycle events and failures
/// from DownloadManager's ring buffer. Details are LocallyError
/// technicalDetails — they never contain tokens or request headers, so the
/// whole log is safe to copy or share.
struct DiagnosticsView: View {
    @State private var events: [DownloadDiagnosticsEvent] = []
    @State private var showCopiedConfirmation = false

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(
                    String(localized: "diagnostics.empty.title"),
                    systemImage: "checklist",
                    description: Text(String(localized: "diagnostics.empty.description"))
                )
            } else {
                // recentDiagnostics returns newest first; keep that order.
                List(events) { event in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(event.detail)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DS.Color.label)
                            .textSelection(.enabled)
                        Text(event.timestamp, format: .dateTime)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryLabel)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "diagnostics.title"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: copyAll) {
                    Image(systemName: showCopiedConfirmation ? "checkmark" : "doc.on.doc")
                }
                .disabled(events.isEmpty)
                .accessibilityLabel(String(localized: "diagnostics.copyAll"))
                ShareLink(item: ShareableLogFile(text: logText()),
                          preview: SharePreview(String(localized: "diagnostics.share.preview"))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(events.isEmpty)
                .accessibilityLabel(String(localized: "diagnostics.share"))
            }
        }
        .overlay(alignment: .bottom) {
            if showCopiedConfirmation {
                Text(String(localized: "diagnostics.copied"))
                    .font(DS.Typography.caption.weight(.medium))
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
                    .padding(.bottom, DS.Spacing.lg)
            }
        }
        .onAppear { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        // DownloadRuntime.holder is set during app init, before any view
        // appears; a nil manager simply shows the empty state.
        events = DownloadRuntime.shared.holder.manager?.recentDiagnostics() ?? []
    }

    private func copyAll() {
        UIPasteboard.general.string = logText()
        withAnimation { showCopiedConfirmation = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { showCopiedConfirmation = false }
        }
    }

    /// Header lines (app version/build, device, OS) plus one line per event.
    /// Details are technicalDetails: no tokens, no URLs with query strings.
    private func logText() -> String {
        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("Locally \(version) (\(build))")
        lines.append("\(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append(String(localized: "diagnostics.exportedAt") + " "
            + ISO8601DateFormatter().string(from: Date()))
        lines.append("")
        let formatter = ISO8601DateFormatter()
        for event in events {
            lines.append("[\(formatter.string(from: event.timestamp))] \(event.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

/// A diagnostics log rendered as a timestamped .txt file for ShareLink.
/// Transferable conformance lets the share sheet hand out a real file
/// instead of a pasted string.
struct ShareableLogFile: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("locally-diagnostics-\(stamp).txt")
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
