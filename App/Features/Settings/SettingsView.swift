import SwiftUI
import LocallyCore

struct SettingsView: View {
    @State private var hfViewModel = HFSettingsViewModel()

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
                huggingFaceSection
            }
            .navigationTitle(String(localized: "tab.settings"))
            .onAppear { hfViewModel.load() }
        }
    }

    private var huggingFaceSection: some View {
        Section {
            if !hfViewModel.hasStoredToken {
                SecureField(
                    String(localized: "hf.token.placeholder", table: "HF"),
                    text: $hfViewModel.tokenInput
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button(String(localized: "hf.token.save", table: "HF")) {
                    hfViewModel.saveToken()
                }
                .disabled(hfViewModel.tokenInput.isEmpty)
            } else {
                if let user = hfViewModel.connectedUser {
                    Label(
                        String(format: String(localized: "hf.connected.as", table: "HF"), user),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(DS.Color.good)
                }
                HStack {
                    Button(String(localized: "hf.token.verify", table: "HF")) {
                        hfViewModel.verify()
                    }
                    .disabled(hfViewModel.isVerifying)
                    if hfViewModel.isVerifying {
                        ProgressView()
                    }
                    Spacer()
                    Button(String(localized: "hf.token.remove", table: "HF"), role: .destructive) {
                        hfViewModel.removeToken()
                    }
                }
            }
            if let error = hfViewModel.errorMessage {
                Text(error)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.bad)
            }
        } header: {
            Text(String(localized: "hf.section.title", table: "HF"))
        } footer: {
            Text(String(localized: "hf.token.footer", table: "HF"))
        }
    }
}
