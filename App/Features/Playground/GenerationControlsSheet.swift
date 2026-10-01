import SwiftUI

/// Generation parameter controls for the chat playground. Values bind
/// directly into the view model and apply to the next message sent.
struct GenerationControlsSheet: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "controls.systemPrompt", table: "Playground")) {
                    TextEditor(text: $viewModel.systemPrompt)
                        .frame(minHeight: 80)
                        .accessibilityLabel(
                            String(localized: "controls.systemPrompt", table: "Playground"))
                }
                Section(String(localized: "controls.sampling", table: "Playground")) {
                    SliderField(
                        title: String(localized: "controls.temperature", table: "Playground"),
                        value: $viewModel.temperature, range: 0...2, format: "%.2f")
                    SliderField(
                        title: String(localized: "controls.topP", table: "Playground"),
                        value: $viewModel.topP, range: 0...1, format: "%.2f")
                    OptionalIntField(
                        title: String(localized: "controls.topK", table: "Playground"),
                        value: $viewModel.topK, range: 1...200, defaultValue: 40)
                }
                Section(String(localized: "controls.limits", table: "Playground")) {
                    Stepper(value: $viewModel.maxTokens, in: 1...4096, step: 64) {
                        LabeledContent(
                            String(localized: "controls.maxTokens", table: "Playground"),
                            value: "\(viewModel.maxTokens)")
                    }
                    OptionalIntField(
                        title: String(localized: "controls.context", table: "Playground"),
                        value: $viewModel.contextLength, range: 256...32768, defaultValue: 4096)
                }
            }
            .navigationTitle(String(localized: "controls.title", table: "Playground"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "controls.done", table: "Playground")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SliderField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            LabeledContent(title, value: String(format: format, value))
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
        }
    }
}

private struct OptionalIntField: View {
    let title: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    let defaultValue: Int

    private var enabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? defaultValue : nil }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Toggle(title, isOn: enabled)
            if value != nil {
                Stepper(value: Binding(
                    get: { value ?? defaultValue },
                    set: { value = $0 }
                ), in: range) {
                    Text("\(value ?? defaultValue)")
                        .font(DS.Typography.body.monospacedDigit())
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
            }
        }
    }
}
