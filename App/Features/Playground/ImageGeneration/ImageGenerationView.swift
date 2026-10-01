import Photos
import SwiftUI
import LocallyCore
import LocallyRuntime

/// Text-to-image playground for Core ML diffusion models. The model's
/// resolution is fixed by its compiled Core ML shape, so the UI shows it as
/// a note rather than offering a picker that cannot work.
struct ImageGenerationView: View {
    @State private var viewModel: ImageGenerationViewModel
    @State private var zoomedIndex: Int?
    @State private var savedNotice = false
    @State private var saveError: String?

    init(model: ModelDescriptor, registry: RuntimeRegistry) {
        _viewModel = State(initialValue: ImageGenerationViewModel(model: model,
                                                                  registry: registry))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                promptSection
                controlsSection
                actionSection
                statusSection
                resultsSection
            }
            .padding(DS.Spacing.md)
        }
        .task { await viewModel.prepareIfNeeded() }
        .onDisappear { viewModel.cancel() }
        .sheet(isPresented: Binding(
            get: { zoomedIndex != nil },
            set: { if !$0 { zoomedIndex = nil } })
        ) {
            if let index = zoomedIndex, viewModel.images.indices.contains(index) {
                ZoomableImageView(data: viewModel.images[index])
            }
        }
        .alert(String(localized: "imagegen.saved.title", table: "ImageGeneration"),
               isPresented: $savedNotice) {
            Button(String(localized: "imagegen.saved.ok", table: "ImageGeneration")) {}
        }
        .alert(String(localized: "imagegen.saveFailed.title", table: "ImageGeneration"),
               isPresented: Binding(get: { saveError != nil },
                                    set: { if !$0 { saveError = nil } })) {
            Button(String(localized: "imagegen.saved.ok", table: "ImageGeneration")) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Sections

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            TextField(String(localized: "imagegen.prompt.placeholder", table: "ImageGeneration"),
                      text: Binding(
                        get: { viewModel.prompt }, set: { viewModel.prompt = $0 }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            TextField(String(localized: "imagegen.negative.placeholder", table: "ImageGeneration"),
                      text: Binding(
                        get: { viewModel.negativePrompt },
                        set: { viewModel.negativePrompt = $0 }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Stepper(String(localized: "imagegen.steps", table: "ImageGeneration")
                    + " \(viewModel.stepCount)",
                    value: Binding(
                        get: { viewModel.stepCount }, set: { viewModel.stepCount = $0 }),
                    in: DiffusionPlanner.stepRange)
            HStack {
                Text(String(localized: "imagegen.guidance", table: "ImageGeneration"))
                Slider(value: Binding(
                    get: { viewModel.guidance }, set: { viewModel.guidance = $0 }),
                    in: DiffusionPlanner.guidanceRange, step: 0.5)
                Text(viewModel.guidance.formatted(.number.precision(.fractionLength(1))))
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                TextField(String(localized: "imagegen.seed.placeholder", table: "ImageGeneration"),
                          text: Binding(
                            get: { viewModel.seedText }, set: { viewModel.seedText = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                Button(String(localized: "imagegen.seed.randomize", table: "ImageGeneration")) {
                    viewModel.seedText = String(UInt32.random(in: 1...UInt32.max))
                }
                .buttonStyle(.bordered)
            }
            if let resolution = viewModel.resolution {
                Label(
                    String(format: String(localized: "imagegen.resolution.fixed",
                                          table: "ImageGeneration"),
                           resolution, resolution),
                    systemImage: "info.circle")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: DS.Spacing.md) {
            if viewModel.isGenerating {
                Button(String(localized: "imagegen.cancel", table: "ImageGeneration"),
                       role: .cancel) {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)
            } else {
                Button(String(localized: "imagegen.generate", table: "ImageGeneration")) {
                    viewModel.generate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canGenerate)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let loadError = viewModel.loadError {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.bad)
        }
        if let phase = viewModel.phase {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(phase).font(DS.Typography.caption)
                if let progress = viewModel.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
        }
        if let error = viewModel.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.bad)
        }
        if let seconds = viewModel.lastSeconds, !viewModel.isGenerating {
            Text(statsLine(seconds: seconds))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryLabel)
        }
    }

    private func statsLine(seconds: Double) -> String {
        var line = String(localized: "imagegen.stats.time", table: "ImageGeneration")
            + " " + seconds.formatted(.number.precision(.fractionLength(1))) + " s"
        if let seed = viewModel.lastSeedUsed {
            line += " · " + String(localized: "imagegen.stats.seed", table: "ImageGeneration")
                + " \(seed)"
        }
        return line
    }

    @ViewBuilder
    private var resultsSection: some View {
        ForEach(Array(viewModel.images.enumerated()), id: \.offset) { index, data in
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .onTapGesture { zoomedIndex = index }
                    .contextMenu {
                        Button(String(localized: "imagegen.save", table: "ImageGeneration")) {
                            Task { await saveToPhotos(data) }
                        }
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview(
                                    String(localized: "imagegen.share.preview",
                                           table: "ImageGeneration"),
                                    image: Image(uiImage: image))) {
                            Label(String(localized: "imagegen.share", table: "ImageGeneration"),
                                  systemImage: "square.and.arrow.up")
                        }
                    }
                HStack {
                    Button(String(localized: "imagegen.save", table: "ImageGeneration")) {
                        Task { await saveToPhotos(data) }
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(
                                String(localized: "imagegen.share.preview",
                                       table: "ImageGeneration"),
                                image: Image(uiImage: image)))
                }
            }
        }
    }

    /// Save only on explicit user tap, asking for add-only authorization.
    private func saveToPhotos(_ data: Data) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveError = String(localized: "imagegen.saveFailed.denied", table: "ImageGeneration")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            savedNotice = true
        } catch {
            saveError = ErrorPresentation.userMessage(for: error)
        }
    }
}

/// Full-screen pinch-to-zoom viewer for a generated PNG.
private struct ZoomableImageView: View {
    let data: Data
    @State private var scale: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnifyGesture().onChanged { value in
                            scale = value.magnification
                        })
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "imagegen.zoom.close", table: "ImageGeneration")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
