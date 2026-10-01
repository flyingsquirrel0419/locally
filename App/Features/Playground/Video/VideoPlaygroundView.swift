import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import LocallyCore
import LocallyRuntime

/// Playground surface for video understanding: pick a video, choose what to
/// ask, analyze with frame sampling, then explore the answer with tappable
/// timestamp chips that seek the preview player.
struct VideoPlaygroundView: View {
    @State private var viewModel: VideoPlaygroundViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var player: AVPlayer?

    init(model: ModelDescriptor, registry: RuntimeRegistry) {
        _viewModel = State(initialValue: VideoPlaygroundViewModel(
            model: model, router: registry.router, device: registry.device))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                if let error = viewModel.lastError {
                    errorBanner(error)
                }
                videoSection
                if viewModel.videoFileURL != nil {
                    modeSection
                    frameBudgetSection
                    runControls
                    if viewModel.isAnalyzing, let phase = viewModel.progressPhase {
                        progressRow(phase)
                    }
                    if !viewModel.answer.isEmpty {
                        answerSection
                    }
                }
            }
            .padding(DS.Spacing.md)
        }
        .navigationTitle(String(localized: "video.title", table: "Video"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.prepareIfNeeded() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await loadPickedVideo(item) }
        }
        .onDisappear {
            viewModel.cleanup()
            player = nil
        }
    }

    // MARK: - Video selection + preview

    private var videoSection: some View {
        Card {
            HStack {
                Text(String(localized: "video.pick.title", table: "Video"))
                    .font(DS.Typography.headline)
                Spacer()
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label(String(localized: "video.pick.button", table: "Video"),
                          systemImage: "video.badge.plus")
                        .font(DS.Typography.body)
                }
            }
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card / 2))
                Text(String(format: "%.1fs", viewModel.videoDuration))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            } else {
                Text(String(localized: "video.pick.empty", table: "Video"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            }
        }
    }

    private var modeSection: some View {
        Card {
            Text(String(localized: "video.mode.title", table: "Video"))
                .font(DS.Typography.headline)
            Picker(String(localized: "video.mode.title", table: "Video"),
                   selection: $viewModel.mode) {
                Text(String(localized: "video.mode.describe", table: "Video"))
                    .tag(VideoAggregationPlanner.Mode.describe)
                Text(String(localized: "video.mode.question", table: "Video"))
                    .tag(VideoAggregationPlanner.Mode.question)
                Text(String(localized: "video.mode.summarize", table: "Video"))
                    .tag(VideoAggregationPlanner.Mode.summarize)
                Text(String(localized: "video.mode.moments", table: "Video"))
                    .tag(VideoAggregationPlanner.Mode.importantMoments)
            }
            .pickerStyle(.menu)
            if viewModel.mode == .question {
                TextField(String(localized: "video.question.placeholder", table: "Video"),
                          text: $viewModel.question)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var frameBudgetSection: some View {
        Card {
            Text(String(localized: "video.frames.title", table: "Video"))
                .font(DS.Typography.headline)
            Picker(String(localized: "video.frames.title", table: "Video"),
                   selection: $viewModel.frameBudget) {
                Text(String(localized: "video.frames.auto", table: "Video"))
                    .tag(VideoPlaygroundViewModel.FrameBudget.auto)
                Text("8").tag(VideoPlaygroundViewModel.FrameBudget.frames8)
                Text("16").tag(VideoPlaygroundViewModel.FrameBudget.frames16)
                Text("32").tag(VideoPlaygroundViewModel.FrameBudget.frames32)
            }
            .pickerStyle(.segmented)
            if let reason = viewModel.planReason {
                Text(reason)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            }
        }
    }

    private var runControls: some View {
        HStack(spacing: DS.Spacing.md) {
            Button {
                viewModel.analyze()
            } label: {
                Label(String(localized: "video.analyze", table: "Video"),
                      systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canAnalyze)

            if viewModel.isAnalyzing {
                Button(String(localized: "video.stop", table: "Video")) {
                    viewModel.stop()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func progressRow(_ phase: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView(value: viewModel.progress)
            Text(phase)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryLabel)
        }
    }

    private var answerSection: some View {
        Card {
            Text(String(localized: "video.answer.title", table: "Video"))
                .font(DS.Typography.headline)
            Text(viewModel.answer)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !viewModel.citedMoments.isEmpty {
                Text(String(localized: "video.moments.title", table: "Video"))
                    .font(DS.Typography.headline)
                    .padding(.top, DS.Spacing.sm)
                ScrollView(.horizontal) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(viewModel.citedMoments) { moment in
                            Button {
                                seek(to: moment.range.start)
                            } label: {
                                Text(String(format: "%.1fs", moment.range.start))
                                    .font(DS.Typography.caption)
                                    .padding(.horizontal, DS.Spacing.sm)
                                    .padding(.vertical, DS.Spacing.xs)
                                    .background(DS.Color.accent.opacity(0.15),
                                                in: Capsule())
                            }
                            .accessibilityLabel(String(
                            format: String(localized: "video.moments.seek",
                                           table: "Video"),
                            moment.range.start))
                        }
                    }
                }
            }
        }
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
    }

    // MARK: - Helpers

    private func loadPickedVideo(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self)
        else {
            viewModel.lastError = String(localized: "video.pick.failed", table: "Video")
            return
        }
        let asset = AVURLAsset(url: movie.url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        viewModel.setVideo(data: movie.url, duration: duration)
        if let url = viewModel.videoFileURL {
            player = AVPlayer(url: url)
        }
    }

    private func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }
}

/// Transferable wrapper for a picked video: copies the transient URL into a
/// temp file we own so the pipeline can reopen it after the picker closes.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("locally-picked-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}
