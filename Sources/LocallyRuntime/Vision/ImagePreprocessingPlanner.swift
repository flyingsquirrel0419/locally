import Foundation
import LocallyCore

/// Pure planner that decides how large an image should be before it is
/// handed to a vision-language model's processor, and what that choice
/// costs in tokens and memory. No platform APIs — fully testable on Linux.
///
/// Two config families are supported, matching what mlx-swift-lm 3.31.4's
/// MLXVLM processors consume:
///   - Qwen2-VL / Qwen2.5-VL style: `patch_size`, `merge_size`,
///     `min_pixels`, `max_pixels` (aspect-preserving smart resize to a
///     multiple of `patch_size × merge_size`, clamped to the pixel range).
///   - SigLIP / LLaVA / PaliGemma style: a fixed `image_size` the processor
///     resizes/crops to.
/// On top of the model's own limits the planner applies an absolute device
/// cap (default: 1536 px long edge) so full-resolution phone photos never
/// reach the encoder.
public struct ImagePreprocessingPlanner: Sendable {

    /// Image constraints parsed from a model's preprocessor_config.json.
    /// All fields optional — absent keys widen estimates rather than fail.
    public struct ProcessorConfig: Codable, Sendable, Hashable {
        /// Qwen-VL style explicit bounds.
        public var patchSize: Int?
        public var mergeSize: Int?
        public var minPixels: Int?
        public var maxPixels: Int?
        /// SigLIP/LLaVA style fixed input. Some configs nest it as
        /// `size: { "shortest_edge": N }`.
        public var imageSize: Int?
        public var shortestEdge: Int?
        public var longestEdge: Int?

        public init(patchSize: Int? = nil, mergeSize: Int? = nil,
                    minPixels: Int? = nil, maxPixels: Int? = nil,
                    imageSize: Int? = nil, shortestEdge: Int? = nil,
                    longestEdge: Int? = nil) {
            self.patchSize = patchSize
            self.mergeSize = mergeSize
            self.minPixels = minPixels
            self.maxPixels = maxPixels
            self.imageSize = imageSize
            self.shortestEdge = shortestEdge
            self.longestEdge = longestEdge
        }

        /// Parse a preprocessor_config.json payload. Recognizes both flat
        /// Qwen-VL keys and nested `size: {shortest_edge, longest_edge}`
        /// / plain `size: N` SigLIP forms. Returns nil when the payload
        /// carries no image-sizing information at all.
        public static func parse(json data: Data) -> ProcessorConfig? {
            guard let object = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else { return nil }
            return parse(dictionary: object)
        }

        static func parse(dictionary object: [String: Any]) -> ProcessorConfig? {
            var config = ProcessorConfig()
            config.patchSize = intValue(object["patch_size"])
            config.mergeSize = intValue(object["merge_size"])
            config.minPixels = intValue(object["min_pixels"])
            config.maxPixels = intValue(object["max_pixels"])
            config.imageSize = intValue(object["image_size"])
            if let size = object["size"] {
                if let nested = size as? [String: Any] {
                    config.shortestEdge = intValue(nested["shortest_edge"])
                    config.longestEdge = intValue(nested["longest_edge"])
                    // SigLIP processors use {"height": N, "width": N}.
                    config.imageSize = config.imageSize
                        ?? intValue(nested["height"])
                        ?? intValue(nested["width"])
                } else if let scalar = intValue(size) {
                    config.shortestEdge = scalar
                }
            }
            let known = [config.patchSize, config.mergeSize, config.minPixels,
                         config.maxPixels, config.imageSize, config.shortestEdge,
                         config.longestEdge]
            return known.contains(where: { $0 != nil }) ? config : nil
        }

        private static func intValue(_ value: Any?) -> Int? {
            switch value {
            case let n as Int: return n
            case let n as Double: return Int(n)
            case let n as NSNumber: return n.intValue
            default: return nil
            }
        }

        /// Qwen-VL style resize factor: patch × merge (28 for Qwen2-VL).
        var resizeFactor: Int? {
            guard let patchSize else { return nil }
            return patchSize * (mergeSize ?? 1)
        }

        /// Effective pixel ceiling from the config alone (no device cap).
        var configMaxPixels: Int? {
            if let maxPixels { return maxPixels }
            if let longestEdge { return longestEdge * longestEdge }
            if let imageSize { return imageSize * imageSize }
            if let shortestEdge { return shortestEdge * shortestEdge }
            return nil
        }
    }

    /// Source image dimensions in pixels.
    public struct PixelSize: Sendable, Hashable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
        public var pixels: Int { width * height }
        public var longEdge: Int { max(width, height) }
    }

    /// The planner's answer for one image.
    public struct Plan: Sendable, Hashable {
        /// Aspect-preserving target size the image should be resampled to
        /// before inference.
        public var target: PixelSize
        /// Estimated image-token count the VLM will see for this image.
        public var estimatedTokens: Int
        /// Estimated bytes for the decoded RGBA pixel buffer at the target
        /// size (4 bytes/px), before model-side patchification.
        public var bufferBytes: Int64
        /// Which rule produced the target size, for diagnostics.
        public var rule: String
    }

    public enum PlannerError: Error, Sendable, Hashable {
        /// Source is degenerate (zero/negative side, or an aspect ratio the
        /// model family rejects — Qwen-VL rejects ratios > 200).
        case unusableSource(reason: String)
    }

    /// Absolute long-edge cap applied on-device regardless of model config.
    /// Phone cameras shoot 3000–12000 px; no mobile VLM benefits beyond
    /// ~1.5K and the decoded buffer cost grows quadratically.
    public var maxLongEdge: Int

    /// Fallback pixel ceiling when the config gives none. Matches the
    /// budget MLXVLM itself applies to Qwen-VL models
    /// (`1280 × factor²` with factor 28 ≈ 1.0 MP); see DECISIONS.md.
    public var fallbackMaxPixels: Int

    public init(maxLongEdge: Int = 1536, fallbackMaxPixels: Int = 1_003_520) {
        self.maxLongEdge = maxLongEdge
        self.fallbackMaxPixels = fallbackMaxPixels
    }

    // MARK: - Planning

    public func plan(source: PixelSize, config: ProcessorConfig) throws -> Plan {
        guard source.width > 0, source.height > 0 else {
            throw PlannerError.unusableSource(reason: "zero-sized image")
        }
        guard source.longEdge / max(1, min(source.width, source.height)) <= 200 else {
            throw PlannerError.unusableSource(
                reason: "aspect ratio exceeds 200:1 (\(source.width)×\(source.height))")
        }

        // Fixed-size family: the processor resizes/crops to imageSize (or
        // shortest/longest edge), so the target is defined by the config,
        // not by our cap — the model never sees anything larger.
        if let fixed = fixedTarget(source: source, config: config) {
            let tokens = fixedTokenEstimate(target: fixed, config: config)
            return Plan(target: fixed, estimatedTokens: tokens,
                        bufferBytes: Int64(fixed.pixels) * 4, rule: "fixed")
        }

        // Qwen-VL style: round to a multiple of factor, clamp pixels.
        let factor = config.resizeFactor ?? 28
        let maxPixels = min(config.configMaxPixels ?? fallbackMaxPixels,
                            maxLongEdge * maxLongEdge)
        var target = Self.smartResize(source: source, factor: factor,
                                      minPixels: config.minPixels,
                                      maxPixels: maxPixels)
        // The pixel budget alone can leave the long edge above the device
        // cap after factor rounding; clamp it explicitly, staying on
        // factor multiples.
        if target.longEdge > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(target.longEdge)
            target = PixelSize(
                width: max(factor, Int((Double(target.width) * scale / Double(factor)).rounded(.down)) * factor),
                height: max(factor, Int((Double(target.height) * scale / Double(factor)).rounded(.down)) * factor))
        }
        let tokens = (target.height / factor) * (target.width / factor)
        return Plan(target: target, estimatedTokens: tokens,
                    bufferBytes: Int64(target.pixels) * 4, rule: "smart-resize")
    }

    /// Convenience: plan straight from a preprocessor_config.json payload.
    /// Unknown/absent config uses the fallback budget.
    public func plan(source: PixelSize, preprocessorJSON data: Data?) throws -> Plan {
        let config = data.flatMap(ProcessorConfig.parse(json:)) ?? ProcessorConfig()
        return try plan(source: source, config: config)
    }

    // MARK: - Rules

    /// Fixed-input family (SigLIP / LLaVA / PaliGemma): the model consumes a
    /// square of `imageSize`, or an aspect-preserving resize bounded by
    /// shortest/longest edge. Returns nil when the config has no fixed size.
    private func fixedTarget(source: PixelSize, config: ProcessorConfig) -> PixelSize? {
        if let imageSize = config.imageSize {
            // Center-crop-to-square models: buffer cost is the square.
            let side = min(imageSize, maxLongEdge)
            return PixelSize(width: side, height: side)
        }
        if let shortest = config.shortestEdge {
            let cappedShortest = min(shortest, maxLongEdge)
            if source.width <= source.height {
                let height = source.width > 0
                    ? cappedShortest * source.height / source.width : cappedShortest
                return clampLongEdge(PixelSize(width: cappedShortest, height: height),
                                     cap: config.longestEdge ?? maxLongEdge)
            }
            let width = cappedShortest * source.width / source.height
            return clampLongEdge(PixelSize(width: width, height: cappedShortest),
                                 cap: config.longestEdge ?? maxLongEdge)
        }
        return nil
    }

    private func clampLongEdge(_ size: PixelSize, cap: Int) -> PixelSize {
        guard size.longEdge > cap else { return size }
        let scale = Double(cap) / Double(size.longEdge)
        return PixelSize(width: max(1, Int((Double(size.width) * scale).rounded(.down))),
                         height: max(1, Int((Double(size.height) * scale).rounded(.down))))
    }

    /// Qwen-VL "smart resize": round each side to the nearest multiple of
    /// `factor`, then scale by sqrt to fit inside [minPixels, maxPixels]
    /// while keeping multiples of factor. Mirrors
    /// `QwenVL.targetSize(height:width:factor:minPixels:maxPixels:)` in
    /// MLXVLM (mlx-swift-lm 3.31.4) so our pre-downsampled image lands on
    /// exactly the size the processor would have chosen.
    static func smartResize(source: PixelSize, factor: Int,
                            minPixels: Int?, maxPixels: Int) -> PixelSize {
        func roundToFactor(_ value: Int) -> Int {
            max(factor, Int((Double(value) / Double(factor)).rounded()) * factor)
        }
        var hBar = roundToFactor(source.height)
        var wBar = roundToFactor(source.width)

        if hBar * wBar > maxPixels {
            let beta = (Double(source.height * source.width) / Double(maxPixels)).squareRoot()
            hBar = max(factor, Int((Double(source.height) / beta / Double(factor)).rounded(.down)) * factor)
            wBar = max(factor, Int((Double(source.width) / beta / Double(factor)).rounded(.down)) * factor)
        } else if let minPixels, hBar * wBar < minPixels {
            let beta = (Double(minPixels) / Double(source.height * source.width)).squareRoot()
            hBar = Int((Double(source.height) * beta / Double(factor)).rounded(.up)) * factor
            wBar = Int((Double(source.width) * beta / Double(factor)).rounded(.up)) * factor
        }
        return PixelSize(width: (wBar / factor) * factor,
                         height: (hBar / factor) * factor)
    }

    /// Token estimate for fixed-size models: (side / patch)², merging down
    /// when mergeSize is known (PaliGemma: imageSize/patch, no merge).
    private func fixedTokenEstimate(target: PixelSize, config: ProcessorConfig) -> Int {
        let patch = config.patchSize ?? 16
        let merge = config.mergeSize ?? 1
        let perSide = max(1, target.height / patch / merge)
        return perSide * perSide
    }
}
