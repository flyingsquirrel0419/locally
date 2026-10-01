import SwiftUI

struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "downloads.empty.title"),
                systemImage: "arrow.down.circle",
                description: Text(String(localized: "downloads.empty.description"))
            )
            .navigationTitle(String(localized: "tab.downloads"))
        }
    }
}
