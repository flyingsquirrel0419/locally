import SwiftUI
import PhotosUI
import LocallyCore
import LocallyRuntime

/// Playground surface for vision-language models: pick images, ask about
/// them, watch the streamed answer. Images transfer as Data (never the
/// full-resolution UIImage) and are downsampled before inference.
struct VisionPlaygroundView: View {
    @State private var viewModel: VisionPlaygroundViewModel
    @State private var selection: [PhotosPickerItem] = []

    init(model: ModelDescriptor, registry: RuntimeRegistry) {
        _viewModel = State(initialValue: VisionPlaygroundViewModel(
            model: model, router: registry.router, device: registry.device))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                if let error = viewModel.lastError {
                    errorBanner(error)
                }
                imageSection
                promptSection
                runControls
                if !viewModel.answer.isEmpty || viewModel.isGenerating {
                    answerSection
                }
                metricsFooter
            }
            .padding(DS.Spacing.md)
        }
        .navigationTitle(String(localized: "vision.title", table: "Vision"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.prepareIfNeeded() }
        .onChange(of: selection) { _, newSelection in
            Task {
                var datas: [Data] = []
                for item in newSelection {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        datas.append(data)
                    }
                }
                selection = []
                await viewModel.addImages(datas: datas)
            }
        }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Sections

    private var imageSection: some View {
        Card {
            HStack {
                Text(String(localized: "vision.images.title", table: "Vision"))
                    .font(DS.Typography.headline)
                Spacer()
                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: viewModel.maxImages,
                    matching: .images
                ) {
                    Label(String(localized: "vision.images.add", table: "Vision"),
                          systemImage: "photo.on.rectangle.angled")
                        .font(DS.Typography.body)
                }
                .disabled(viewModel.images.count >= viewModel.maxImages)
            }
            if viewModel.images.isEmpty {
                Text(String(localized: "vision.images.empty", table: "Vision"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(viewModel.images) { image in
                            thumbnail(for: image)
                        }
                    }
                }
                if let summary = viewModel.planSummary {
                    Text(summary)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
            }
        }
    }

    private func thumbnail(for image: VisionPlaygroundViewModel.PickedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: image.thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card / 2))
            }
            Button {
                viewModel.removeImage(id: image.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DS.Color.secondaryLabel)
                    .background(Circle().fill(DS.Color.background))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel(String(localized: "vision.images.remove", table: "Vision"))
        }
    }

    private var promptSection: some View {
        Card {
            Text(String(localized: "vision.prompt.title", table: "Vision"))
                .font(DS.Typography.headline)
            TextEditor(text: $viewModel.prompt)
                .frame(minHeight: 72)
                .font(DS.Typography.body)
                .scrollContentBackground(.hidden)
                .background(DS.Color.background,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card / 2))
        }
    }

    private var runControls: some View {
        HStack(spacing: DS.Spacing.md) {
            Button {
                viewModel.run()
            } label: {
                Label(String(localized: "vision.run", table: "Vision"),
                      systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canRun)

            if viewModel.isGenerating {
                ProgressView()
                Button(String(localized: "vision.stop", table: "Vision")) {
                    viewModel.stop()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var answerSection: some View {
        Card {
            Text(String(localized: "vision.answer.title", table: "Vision"))
                .font(DS.Typography.headline)
            Text(viewModel.answer)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metricsFooter: some View {
        HStack(spacing: DS.Spacing.md) {
            metric(String(localized: "metrics.ttft", table: "Playground"),
                   viewModel.metrics.ttft.map { String(format: "%.2fs", $0) } ?? "–")
            metric(String(localized: "metrics.toks", table: "Playground"),
                   viewModel.metrics.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "–")
            if let count = viewModel.metrics.generatedTokens {
                metric(String(localized: "metrics.tokens", table: "Playground"),
                       "\(count)")
            }
        }
        .font(DS.Typography.caption)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(title).foregroundStyle(DS.Color.secondaryLabel)
            Text(value).foregroundStyle(DS.Color.label).monospacedDigit()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DS.Color.warning)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.label)
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.secondaryBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}
