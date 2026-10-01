import SwiftUI
import LocallyCore
import LocallyRuntime

/// Playground surface for decision models: a state editor, a question
/// builder (with a raw-JSON toggle), and result cards. Every value shown
/// comes from a real runtime event or the schema parser — nothing is
/// simulated.
struct DecisionPlaygroundView: View {
    @State private var viewModel: DecisionPlaygroundViewModel
    private let model: ModelDescriptor

    init(model: ModelDescriptor, router: RuntimeRouter, device: DeviceCapabilities) {
        self.model = model
        _viewModel = State(initialValue: DecisionPlaygroundViewModel(
            model: model, router: router, device: device))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                if let error = viewModel.lastError {
                    errorBanner(error)
                }
                stateEditor
                editorToggle
                if viewModel.editingRawJSON {
                    rawEditor
                } else {
                    questionBuilder
                }
                if let schemaError = viewModel.schemaError {
                    schemaErrorBanner(schemaError)
                }
                runControls
                resultsSection
            }
            .padding(DS.Spacing.md)
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.prepareIfNeeded() }
    }

    // MARK: - Sections

    private var stateEditor: some View {
        Card {
            Text(String(localized: "decision.state.title", table: "Decision"))
                .font(DS.Typography.headline)
            TextEditor(text: $viewModel.stateText)
                .frame(minHeight: 80)
                .font(DS.Typography.body)
                .scrollContentBackground(.hidden)
                .background(DS.Color.background,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card / 2))
        }
    }

    private var editorToggle: some View {
        Toggle(String(localized: "decision.rawJSON.toggle", table: "Decision"),
               isOn: Binding(
                get: { viewModel.editingRawJSON },
                set: { newValue in
                    if newValue {
                        viewModel.syncRawFromBuilder()
                    } else {
                        viewModel.syncBuilderFromRaw()
                    }
                    viewModel.editingRawJSON = newValue
                }))
            .font(DS.Typography.body)
            .padding(.horizontal, DS.Spacing.xs)
    }

    private var rawEditor: some View {
        Card {
            Text(String(localized: "decision.rawJSON.title", table: "Decision"))
                .font(DS.Typography.headline)
            TextEditor(text: $viewModel.rawSchemaText)
                .frame(minHeight: 200)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(DS.Color.background,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card / 2))
        }
    }

    private var questionBuilder: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(viewModel.questions) { question in
                questionCard(question)
            }
            Button(String(localized: "decision.question.add", table: "Decision"),
                   systemImage: "plus") {
                viewModel.addQuestion()
            }
            .buttonStyle(.bordered)
        }
    }

    private func questionCard(_ question: DecisionPlaygroundViewModel.EditableQuestion) -> some View {
        let index = viewModel.questions.firstIndex(where: { $0.id == question.id })!
        let binding = $viewModel.questions[index]
        return Card {
            HStack {
                TextField(String(localized: "decision.question.key", table: "Decision"),
                          text: binding.key)
                    .font(DS.Typography.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Spacer()
                Button(role: .destructive) {
                    viewModel.removeQuestion(question.id)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(String(localized: "decision.question.remove", table: "Decision"))
            }
            Picker(String(localized: "decision.question.type", table: "Decision"),
                   selection: binding.kind) {
                ForEach(DecisionPlaygroundViewModel.EditableQuestion.Kind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.menu)
            TextField(String(localized: "decision.question.instructions", table: "Decision"),
                      text: binding.instructions, axis: .vertical)
                .font(DS.Typography.body)
            switch question.kind {
            case .choice, .multiChoice, .ranking:
                TextField(String(localized: "decision.question.options", table: "Decision"),
                          text: binding.optionsText, axis: .vertical)
                    .font(DS.Typography.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .score:
                HStack {
                    Stepper("min \(formatNumber(question.scoreMin))",
                            value: binding.scoreMin, step: question.scoreInteger ? 1 : 0.5)
                    Stepper("max \(formatNumber(question.scoreMax))",
                            value: binding.scoreMax, step: question.scoreInteger ? 1 : 0.5)
                }
                .font(DS.Typography.caption)
                Toggle(String(localized: "decision.question.integer", table: "Decision"),
                       isOn: binding.scoreInteger)
                    .font(DS.Typography.caption)
            case .structured:
                TextEditor(text: binding.schemaText)
                    .frame(minHeight: 100)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(DS.Color.background,
                                in: RoundedRectangle(cornerRadius: DS.Radius.card / 2))
            case .boolean, .probability, .noul:
                EmptyView()
            }
        }
    }

    private var runControls: some View {
        HStack(spacing: DS.Spacing.md) {
            if viewModel.isPreparing {
                ProgressView()
                Text(String(localized: "decision.preparing", table: "Decision"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            } else if viewModel.isRunning {
                ProgressView()
                Button(String(localized: "decision.stop", table: "Decision")) {
                    viewModel.stop()
                }
                .buttonStyle(.bordered)
            } else {
                Button(String(localized: "decision.run", table: "Decision"),
                       systemImage: "play.fill") {
                    viewModel.run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.prepared)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(viewModel.results) { result in
                resultCard(result)
            }
        }
    }

    private func resultCard(_ result: DecisionPlaygroundViewModel.AnsweredQuestion) -> some View {
        Card {
            HStack {
                Text(result.key)
                    .font(DS.Typography.headline.monospaced())
                Spacer()
                Text(result.method)
                    .font(DS.Typography.caption)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(DS.Color.accent.opacity(0.15),
                                in: Capsule())
            }
            Text(result.valueText)
                .font(DS.Typography.body)
            if let probability = result.probability {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ProgressView(value: probability)
                        .tint(DS.Color.accent)
                    Text(String(format: "%.1f%%", probability * 100))
                        .font(DS.Typography.caption.monospacedDigit())
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
            }
            MetricRow(title: String(localized: "decision.result.latency", table: "Decision"),
                      value: String(format: "%.2f s", result.latency),
                      systemImage: "clock")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Card {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.bad)
        }
    }

    private func schemaErrorBanner(_ message: String) -> some View {
        Card {
            Label {
                Text(message)
                    .font(DS.Typography.caption.monospaced())
            } icon: {
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(DS.Color.warning)
            }
        }
    }

    private func formatNumber(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }
}
