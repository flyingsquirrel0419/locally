import SwiftUI

@main
struct LocallyApp: App {
    @UIApplicationDelegateAdaptor(LocallyAppDelegate.self) private var appDelegate

    init() {
        // Start the shared download runtime at launch; the HF token provider
        // is wired by the app layer so tokens never touch storage.
        DownloadRuntime.shared.start(authHeaderProvider: { _ in nil })
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(DownloadRuntime.shared.holder)
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
