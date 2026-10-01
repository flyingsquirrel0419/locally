import SwiftUI

@main
struct LocallyApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label(String(localized: "tab.home"), systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
            ModelsView()
                .tabItem {
                    Label(String(localized: "tab.models"), systemImage: "shippingbox")
                }
            PlaygroundView()
                .tabItem {
                    Label(String(localized: "tab.playground"), systemImage: "bubble.left.and.text.bubble.right")
                }
            DownloadsView()
                .tabItem {
                    Label(String(localized: "tab.downloads"), systemImage: "arrow.down.circle")
                }
            SettingsView()
                .tabItem {
                    Label(String(localized: "tab.settings"), systemImage: "gearshape")
                }
        }
    }
}
