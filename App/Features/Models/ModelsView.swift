import SwiftUI

struct ModelsView: View {
    @State private var showAddModel = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "models.empty.title"),
                systemImage: "shippingbox",
                description: Text(String(localized: "models.empty.description"))
            )
            .navigationTitle(String(localized: "tab.models"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "models.add.button", table: "HF"),
                           systemImage: "plus") {
                        showAddModel = true
                    }
                }
            }
            .sheet(isPresented: $showAddModel) {
                AddModelSheet()
            }
        }
    }
}
