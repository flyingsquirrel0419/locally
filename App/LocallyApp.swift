import SwiftUI
import LocallyHF

@main
struct LocallyApp: App {
    @UIApplicationDelegateAdaptor(LocallyAppDelegate.self) private var appDelegate

    init() {
        // Start the shared download runtime at launch; the HF token provider
        // reads Keychain at request time so tokens never touch storage.
        DownloadRuntime.shared.start(authHeaderProvider: { url in
            guard let host = url.host, RedirectPolicy.isAllowedHFHost(host) else { return nil }
            #if canImport(Security)
            guard let token = try? KeychainTokenStore().readToken(), !token.isEmpty else { return nil }
            return "Bearer \(token)"
            #else
            return nil
            #endif
        })
        ModelLibraryRuntime.shared.start()
        // Runtime registry + cross-tab navigation for the playground.
        AppRuntime.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(DownloadRuntime.shared.holder)
                .environment(ModelLibraryRuntime.shared.holder)
                .environment(AppRuntime.shared.runtimeHolder)
                .environment(AppRuntime.shared.navigation)
        }
    }
}

/// Which top-level tab is showing; "Run in Playground" flips this.
final class TabSelection: ObservableObject {
    @Published var selection: Tab = .home

    enum Tab: Hashable {
        case home, models, playground, downloads, settings
    }
}

struct RootTabView: View {
    @StateObject private var tabSelection = TabSelection()

    var body: some View {
        TabView(selection: $tabSelection.selection) {
            HomeView()
                .tabItem {
                    Label(String(localized: "tab.home"), systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
                .tag(TabSelection.Tab.home)
            ModelsView()
                .tabItem {
                    Label(String(localized: "tab.models"), systemImage: "shippingbox")
                }
                .tag(TabSelection.Tab.models)
            PlaygroundView()
                .tabItem {
                    Label(String(localized: "tab.playground"), systemImage: "bubble.left.and.text.bubble.right")
                }
                .tag(TabSelection.Tab.playground)
            DownloadsView()
                .tabItem {
                    Label(String(localized: "tab.downloads"), systemImage: "arrow.down.circle")
                }
                .tag(TabSelection.Tab.downloads)
            SettingsView()
                .tabItem {
                    Label(String(localized: "tab.settings"), systemImage: "gearshape")
                }
                .tag(TabSelection.Tab.settings)
        }
        .environmentObject(tabSelection)
    }
}
