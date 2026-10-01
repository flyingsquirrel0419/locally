import Foundation
import LocallyCore

/// Core ML diffusion variant selection (apple/coreml-stable-diffusion-* layout).
extension RepositoryAnalyzer {

    /// One runnable variant of a Core ML diffusion repo: either a folder of
    /// compiled .mlmodelc trees or a zip archive containing them.
    struct CoreMLDiffusionVariant: Sendable {
        enum Form: Sendable { case folder, archive }
        /// "split_einsum" or "original".
        var attention: String
        var form: Form
        var palettized: Bool
        /// Repo-relative directory the pipeline loads from (the folder
        /// itself, or the archive's stem — extraction lands next to the zip).
        var resourceDirectory: String
        /// The zip file when the variant ships as an archive.
        var archiveFile: HFSibling?
        /// Fixed output resolution: SDXL models are 1024, SD 1.x/2.x 512.
        var resolution: Int?
    }

    /// Pick the iPhone variant of a Core ML diffusion repo. Apple's layout
    /// (verified against apple/coreml-stable-diffusion-2-1-base-palettized):
    /// `<variant>/compiled/*.mlmodelc` folders plus `<variant>/packages`,
    /// and one `<repo>_<variant>_compiled.zip` per variant. split_einsum is
    /// required for Neural Engine execution (original attention needs a
    /// GPU); palettized is smaller; archives are preferred when both exist
    /// because the install pipeline extracts them atomically.
    func pickCoreMLDiffusionVariant(siblings: [HFSibling], repoName: String) -> CoreMLDiffusionVariant? {
        let lower = repoName.lowercased()
        let isXL = lower.contains("xl")
        let resolution = isXL ? 1024 : 512

        struct Candidate {
            var attention: String
            var palettized: Bool
            var archive: HFSibling?
            var folderPrefix: String?
            var score: Int
        }
        var candidates: [Candidate] = []

        // Archives: "<name>_<variant>_compiled.zip" or "<variant>_compiled.zip"
        for sibling in siblings where sibling.rfilename.lowercased().hasSuffix(".zip") {
            let base = sibling.rfilename.lowercased()
            guard base.contains("compiled") else { continue }
            let attention: String
            if base.contains("split_einsum") { attention = "split_einsum" }
            else if base.contains("original") { attention = "original" }
            else { continue }
            let palettized = base.contains("palettized") || lower.contains("palettized")
            // split_einsum strongly preferred on iPhone; archives preferred.
            var score = attention == "split_einsum" ? 100 : 0
            if palettized { score += 10 }
            candidates.append(Candidate(
                attention: attention, palettized: palettized, archive: sibling,
                folderPrefix: nil, score: score))
        }

        // Folders: "<variant>/compiled/TextEncoder.mlmodelc/..." trees.
        let folderPrefixes = Set(siblings.compactMap { sibling -> String? in
            let path = sibling.rfilename
            guard path.lowercased().contains(".mlmodelc/") else { return nil }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[1].lowercased() == "compiled" else { return nil }
            return parts[0]
        })
        for prefix in folderPrefixes {
            let p = prefix.lowercased()
            let attention = p.contains("split_einsum") ? "split_einsum"
                : p.contains("original") ? "original" : "split_einsum"
            let palettized = p.contains("palettized") || lower.contains("palettized")
            var score = attention == "split_einsum" ? 90 : -10
            if palettized { score += 10 }
            candidates.append(Candidate(
                attention: attention, palettized: palettized, archive: nil,
                folderPrefix: "\(prefix)/compiled", score: score))
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        if let archive = best.archive {
            let stem = archive.rfilename.hasSuffix(".zip")
                ? String(archive.rfilename.dropLast(4)) : archive.rfilename
            return CoreMLDiffusionVariant(
                attention: best.attention, form: .archive, palettized: best.palettized,
                resourceDirectory: stem, archiveFile: archive, resolution: resolution)
        }
        guard let prefix = best.folderPrefix else { return nil }
        return CoreMLDiffusionVariant(
            attention: best.attention, form: .folder, palettized: best.palettized,
            resourceDirectory: prefix, archiveFile: nil, resolution: resolution)
    }
}
