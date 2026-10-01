import Foundation
import LocallyCore

/// Runtime-file selection: which repo files a download actually needs.
extension RepositoryAnalyzer {

    /// The files actually needed to run: the chosen variant's weights plus
    /// config/tokenizer/support files. Excludes other quantizations, .bin
    /// duplicates when safetensors exist, alternative framework formats, and
    /// docs/images.
    func selectRequiredFiles(siblings: [HFSibling], ggufVariant: HFSibling?,
                             formats: [ModelFormat],
                             diffusionVariant: CoreMLDiffusionVariant? = nil) -> [RemoteModelFile] {
        let hasGGUF = formats.contains(.gguf)
        let hasSafetensors = formats.contains(.safetensors) || formats.contains(.mlx)

        // Core ML diffusion: exactly one variant — the archive (or folder)
        // contents — plus the top-level tokenizer files the pipeline loads.
        if let variant = diffusionVariant {
            return siblings.compactMap { sibling in
                let path = sibling.rfilename
                let lower = path.lowercased()
                if lower.hasPrefix(".git") { return nil }
                if Self.isNonRuntimeFile(lower) { return nil }
                let included: Bool
                switch variant.form {
                case .archive:
                    included = path == variant.archiveFile?.rfilename
                        || path == "vocab.json" || path == "merges.txt"
                case .folder:
                    included = path.hasPrefix(variant.resourceDirectory + "/")
                        || path == "vocab.json" || path == "merges.txt"
                }
                guard included else { return nil }
                let size = sibling.lfs?.size ?? sibling.size ?? 0
                return RemoteModelFile(path: path, size: size, sha256: sibling.lfs?.sha256)
            }
        }

        return siblings.compactMap { sibling in
            let path = sibling.rfilename
            let lower = path.lowercased()

            if lower.hasPrefix(".git") { return nil }
            if Self.isNonRuntimeFile(lower) { return nil }
            if lower.hasSuffix(".gguf") {
                guard let variant = ggufVariant, path == variant.rfilename else { return nil }
            } else if lower.hasSuffix(".bin") {
                if hasSafetensors || hasGGUF { return nil }
            } else if lower.hasSuffix(".safetensors") {
                if hasGGUF { return nil }
            } else if lower.hasSuffix(".onnx") || lower.hasSuffix(".mlpackage")
                        || lower.hasSuffix(".mlmodelc") || lower.hasSuffix(".pt")
                        || lower.hasSuffix(".pth") || lower.hasSuffix(".ckpt")
                        || lower.hasSuffix(".h5") || lower.hasSuffix(".msgpack")
                        || lower.hasSuffix(".tflite") {
                // Alternate framework formats are not required once a primary
                // format (GGUF/MLX/safetensors) is chosen.
                if hasGGUF || hasSafetensors || formats.contains(.coreml) == false { return nil }
            }

            let size = sibling.lfs?.size ?? sibling.size ?? 0
            return RemoteModelFile(path: path, size: size, sha256: sibling.lfs?.sha256)
        }
    }

    /// Top-level safetensors weight shards ("model.safetensors",
    /// "model-NNNNN-of-NNNNN.safetensors"), excluding sub-component files
    /// (diffusion unet/vae/text_encoder live in subdirectories).
    static func primarySafetensors(siblings: [HFSibling]) -> [HFSibling] {
        siblings.filter {
            $0.rfilename.lowercased().hasSuffix(".safetensors")
                && !$0.rfilename.contains("/")
        }
    }

    /// Files that never belong in a runtime download: llama.cpp importance
    /// matrices (calibration data for quantizing, not inference), docs,
    /// images, VCS attributes, licenses, and other metadata-only artifacts.
    /// `lower` is already lowercased.
    static func isNonRuntimeFile(_ lower: String) -> Bool {
        if lower.hasSuffix(".imatrix") { return true }
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
            || lower.hasSuffix(".pdf") { return true }
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".svg")
            || lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return true }
        let base = (lower as NSString).lastPathComponent
        if base == ".gitattributes" || base == ".gitignore" || base == "license"
            || base == "license.txt" || base == "license.md" || base == "copying"
            || base == "notice" || base == "authors" || base == "contributors" { return true }
        return false
    }
}
