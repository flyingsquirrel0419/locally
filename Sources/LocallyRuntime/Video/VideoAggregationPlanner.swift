import Foundation
import LocallyCore

/// A half-open time range within a video, in seconds.
public struct TimeRange: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Pure prompt + parsing logic for the map-reduce video pipeline:
/// per-batch prompts carry timestamp labels, a final aggregation prompt
/// combines batch answers, and cited timestamps are parsed back into
/// validated `TimeRange` results. Testable on Linux.
public struct VideoAggregationPlanner: Sendable {

    /// What the user wants out of the video.
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        /// Free description of what happens.
        case describe
        /// Answer a specific question about the video.
        case question
        /// Condense the video into a short summary.
        case summarize
        /// Identify notable moments; the model is asked to cite timestamps
        /// and its "t=…" references are parsed into `TimeRange`s.
        case importantMoments
    }

    public init() {}

    // MARK: - Prompts

    /// Prompt for one batch of frames. Each frame is timestamped; the model
    /// is told which `[t=…]` label belongs to which image in order.
    public func batchPrompt(mode: Mode, question: String?,
                            timestamps: [TimeInterval]) -> String {
        let labels = timestamps.map { Self.formatTimestamp($0) }.joined(separator: ", ")
        let header = "These \(timestamps.count) frames were sampled at \(labels), in order."
        let instruction: String
        switch mode {
        case .describe:
            instruction = "Describe what is happening across these frames, referencing the timestamps (like [t=12.4s]) when something changes."
        case .question:
            instruction = "Answer this question about the frames, citing timestamps (like [t=12.4s]) for anything you reference: \(question ?? "")"
        case .summarize:
            instruction = "Summarize what these frames show in one or two sentences, citing the timestamps (like [t=12.4s]) of anything notable."
        case .importantMoments:
            instruction = "List the most important moments visible in these frames, one per line, each starting with its timestamp like [t=12.4s]."
        }
        return "\(header)\n\(instruction)"
    }

    /// Prompt for the reduce step: combine per-batch answers into one
    /// final answer.
    public func aggregationPrompt(mode: Mode, question: String?,
                                  batchAnswers: [String]) -> String {
        let joined = batchAnswers.enumerated().map { index, answer in
            "Segment \(index + 1):\n\(answer)"
        }.joined(separator: "\n\n")
        let instruction: String
        switch mode {
        case .describe:
            instruction = "Combine these segment descriptions into one coherent description of the whole video, keeping the [t=…s] timestamp references."
        case .question:
            instruction = "Using only these segment answers, answer the original question about the whole video: \(question ?? "") Keep the [t=…s] timestamp references for anything you cite."
        case .summarize:
            instruction = "Combine these segment summaries into one concise summary of the whole video, keeping the [t=…s] timestamp references."
        case .importantMoments:
            instruction = "From these segment notes, list the most important moments of the whole video, one per line, each starting with its timestamp like [t=12.4s]. Drop duplicates and keep chronological order."
        }
        return "A video was analyzed in \(batchAnswers.count) segments. Here are the per-segment answers:\n\n\(joined)\n\n\(instruction)"
    }

    /// Timestamp label used in prompts and parsed back out of answers.
    public static func formatTimestamp(_ seconds: TimeInterval) -> String {
        "[t=\(String(format: "%.1f", seconds))s]"
    }

    // MARK: - Timestamp citation parsing

    /// Parse "[t=12.4s]" style citations out of a model answer into time
    /// ranges. A single citation becomes a ±2 s window around the cited
    /// point; ranges are clamped to [0, duration] and dropped when they
    /// fall entirely outside it.
    public static func citedRanges(in text: String,
                                   duration: TimeInterval,
                                   window: TimeInterval = 2.0) -> [TimeRange] {
        var ranges: [TimeRange] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "[t=", range: searchStart ..< text.endIndex) {
            let numberStart = open.upperBound
            guard let close = text[numberStart...].firstIndex(of: "]") else { break }
            var raw = text[numberStart ..< close]
            if raw.hasSuffix("s") { raw = raw.dropLast() }
            searchStart = close
            guard let seconds = Double(raw), seconds.isFinite else { continue }
            let start = max(0, seconds - window)
            let end = min(duration, seconds + window)
            guard end > start else { continue }
            let candidate = TimeRange(start: start, end: end)
            if !ranges.contains(candidate) { ranges.append(candidate) }
        }
        return ranges.sorted { $0.start < $1.start }
    }
}
