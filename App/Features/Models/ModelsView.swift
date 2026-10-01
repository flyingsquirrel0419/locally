import SwiftUI

struct ModelsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "models.empty.title"),
                systemImage: "shippingbox",
                description: Text(String(localized: "models.empty.description"))
            )
            .navigationTitle(String(localized: "tab.models"))
        }
    }
}
