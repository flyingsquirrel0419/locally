import SwiftUI

struct PlaygroundView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "playground.empty.title"),
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text(String(localized: "playground.empty.description"))
            )
            .navigationTitle(String(localized: "tab.playground"))
        }
    }
}
