import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "settings.about")) {
                    MetricRow(
                        title: String(localized: "settings.version"),
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                               as? String ?? "0.1.0"
                    )
                }
            }
            .navigationTitle(String(localized: "tab.settings"))
        }
    }
}
