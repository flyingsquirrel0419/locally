import SwiftUI
import LocallyCore
import LocallyRuntime

/// Streaming chat surface for text models in the playground.
struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var showControls = false

    init(model: ModelDescriptor, registry: RuntimeRegistry) {
        _viewModel = State(initialValue: ChatViewModel(
            model: model, router: registry.router, device: registry.device,
            onInferenceCompleted: { metadata in
                // Registry id is "\(repoID)@\(revision)"; the analyzer stores
                // the revision in descriptor.metadata at install time.
                let id = "\(model.repoID)@\(model.metadata["revision"] ?? "main")"
                // ModelLibraryRuntime.shared is MainActor state; hop there
                // first, then call into the registry actor.
                Task { @MainActor in
                    let registry = ModelLibraryRuntime.shared.holder.registry
                    try? await registry?.recordBenchmark(id: id, sample: metadata)
                }
            }))
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            metricsFooter
            inputBar
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: DS.Spacing.md) {
                    Button(String(localized: "chat.clear", table: "Playground"),
                           systemImage: "trash") {
                        viewModel.clearConversation()
                    }
                    .disabled(viewModel.messages.isEmpty || viewModel.isGenerating)
                    Button(String(localized: "chat.controls", table: "Playground"),
                           systemImage: "slider.horizontal.3") {
                        showControls = true
                    }
                }
            }
        }
        .sheet(isPresented: $showControls) {
            GenerationControlsSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.prepareIfNeeded()
        }
    }

    @ViewBuilder
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    if let error = viewModel.lastError {
                        errorBanner(error)
                    }
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if viewModel.isGenerating {
                        HStack(spacing: DS.Spacing.sm) {
                            ProgressView()
                            Button(String(localized: "chat.stop", table: "Playground")) {
                                viewModel.stop()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, DS.Spacing.md)
                    }
                }
                .padding(.vertical, DS.Spacing.sm)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let last = viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        Text(String(localized: "chat.empty", table: "Playground"))
            .font(DS.Typography.body)
            .foregroundStyle(DS.Color.secondaryLabel)
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.lg)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DS.Color.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.label)
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.secondaryBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .padding(.horizontal, DS.Spacing.md)
    }

    private var metricsFooter: some View {
        HStack(spacing: DS.Spacing.md) {
            metric(String(localized: "metrics.load", table: "Playground"),
                   ChatViewModel.formatSeconds(viewModel.metrics.loadTime))
            metric(String(localized: "metrics.ttft", table: "Playground"),
                   ChatViewModel.formatSeconds(viewModel.metrics.ttft))
            metric(String(localized: "metrics.toks", table: "Playground"),
                   ChatViewModel.formatRate(viewModel.metrics.tokensPerSecond))
            if let count = viewModel.metrics.generatedTokens {
                metric(String(localized: "metrics.tokens", table: "Playground"), "\(count)")
            }
        }
        .font(DS.Typography.caption.monospacedDigit())
        .foregroundStyle(DS.Color.secondaryLabel)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(title)
            Text(value).foregroundStyle(DS.Color.label)
        }
    }

    private var inputBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField(String(localized: "chat.input.placeholder", table: "Playground"),
                      text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .disabled(!viewModel.isRunnable || viewModel.isGenerating)
            Button(action: { viewModel.send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !viewModel.isRunnable || viewModel.isGenerating)
            .accessibilityLabel(String(localized: "chat.send", table: "Playground"))
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Color.secondaryBackground)
    }
}

private struct MessageBubble: View {
    let message: ChatViewModel.Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: DS.Spacing.lg) }
            Text(message.content.isEmpty ? " " : message.content)
                .font(DS.Typography.body)
                .foregroundStyle(isUser ? .white : DS.Color.label)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(
                    isUser ? DS.Color.accent : DS.Color.secondaryBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                )
            if !isUser { Spacer(minLength: DS.Spacing.lg) }
        }
        .padding(.horizontal, DS.Spacing.md)
        .accessibilityLabel(isUser
            ? String(localized: "chat.message.you", table: "Playground")
            : String(localized: "chat.message.assistant", table: "Playground"))
    }
}
