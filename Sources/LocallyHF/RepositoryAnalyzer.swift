import Foundation
import LocallyCore

/// Builds a ModelDescriptor from a repository's file listing plus its small
/// config files. Pure analysis — repository code is never executed, and
/// configs that request it are flagged via `requiresRemoteCode` metadata.
public struct RepositoryAnalyzer: Sendable {

    /// Small config files fetched (capped) when present in the repo listing.
    private static let configCandidates = [
        "config.json", "model_index.json", "preprocessor_config.json",
        "tokenizer_config.json", "generation_config.json",
    ]

    public init() {}

    /// Full analysis: fetches repo metadata and configs through the client.
    public func analyze(_ reference: HFRepoReference, client: HFClient) async throws -> ModelDescriptor {
        let info = try await client.repoInfo(reference.repoID, revision: reference.revision)
        let revision = reference.revision ?? info.sha ?? "main"
        let siblings = info.siblings ?? []
        let fileNames = Set(siblings.map(\.rfilename))

        var configs: [String: ModelConfig] = [:]
        var readmeFrontMatter: CardFrontMatter?
        for name in Self.configCandidates {
            guard fileNames.contains(name) else { continue }
            if let data = try? await client.fetchSmallFile(reference.repoID, revision: revision, path: name),
               let config = try? ModelConfig(data: data) {
                configs[name] = config
            }
        }
        if fileNames.contains("README.md"),
           let data = try? await client.fetchSmallFile(reference.repoID, revision: revision, path: "README.md"),
           let text = String(data: data, encoding: .utf8) {
            readmeFrontMatter = CardFrontMatter(markdown: text)
        }

        // Safetensors headers give ground-truth parameter counts; sum across
        // all weight shards (index/metadata shards excluded). MLX repos pack
        // quantized weights as U32, so pass the declared bit width to expand
        // shapes back to logical parameter counts.
        var safetensorsHeader: ModelHeaderParser.SafetensorsHeader?
        let packedBits = configs["config.json"]?.declaredQuantization?.bits
        let weightShards = Self.primarySafetensors(siblings: siblings)
        if !weightShards.isEmpty {
            var totalParams: Int64 = 0
            var dtypes: [String: Int64] = [:]
            var parsedAny = false
            for shard in weightShards {
                guard let prefix = try? await client.fetchRange(
                    reference.repoID, revision: revision, path: shard.rfilename,
                    length: ModelHeaderParser.SafetensorsHeader.maxHeaderBytes
                ), let header = try? ModelHeaderParser.parseSafetensors(prefix, packedBits: packedBits) else { continue }
                totalParams += header.parameterCount
                for (dtype, count) in header.dtypes {
                    dtypes[dtype, default: 0] += count
                }
                parsedAny = true
            }
            if parsedAny {
                safetensorsHeader = .init(parameterCount: totalParams, dtypes: dtypes)
            }
        }

        // GGUF repos carry no config.json; the GGUF header itself is the
        // ground truth for architecture, parameter count, context length,
        // and the chat template. Range-fetch the chosen variant's header
        // (8 MB cap; one growth to 32 MB for very chat-template-heavy files).
        let ggufVariant = pickGGUFVariant(siblings: siblings)
        var ggufHeader: GGUFParser.Header?
        if let variant = ggufVariant {
            ggufHeader = await Self.fetchGGUFHeader(
                repoID: reference.repoID, revision: revision,
                path: variant.rfilename, client: client)
        }

        return buildDescriptor(
            reference: reference, revision: revision, info: info,
            siblings: siblings, configs: configs,
            frontMatter: readmeFrontMatter, safetensorsHeader: safetensorsHeader,
            ggufHeader: ggufHeader, ggufVariant: ggufVariant
        )
    }

    /// Offline analysis from an already-fetched repo listing (used by tests
    /// and by the live-check script's fixture path).
    public func analyze(info: HFRepoInfo, configs: [String: ModelConfig],
                        frontMatter: CardFrontMatter?,
                        safetensorsHeader: ModelHeaderParser.SafetensorsHeader?,
                        reference: HFRepoReference) -> ModelDescriptor {
        buildDescriptor(
            reference: reference, revision: reference.revision ?? info.sha ?? "main",
            info: info, siblings: info.siblings ?? [], configs: configs,
            frontMatter: frontMatter, safetensorsHeader: safetensorsHeader,
            ggufHeader: nil, ggufVariant: nil
        )
    }

    // MARK: - Descriptor assembly

    private func buildDescriptor(
        reference: HFRepoReference, revision: String, info: HFRepoInfo,
        siblings: [HFSibling], configs: [String: ModelConfig],
        frontMatter: CardFrontMatter?, safetensorsHeader: ModelHeaderParser.SafetensorsHeader?,
        ggufHeader: GGUFParser.Header?, ggufVariant: HFSibling?
    ) -> ModelDescriptor {
        let config = configs["config.json"]
        let tags = Set((info.tags ?? []) + (frontMatter?.tags ?? []))
        let pipelineTag = info.pipelineTag ?? frontMatter?.pipelineTag
        let libraryName = info.libraryName ?? frontMatter?.libraryName

        let modality = detectModality(pipelineTag: pipelineTag, config: config,
                                      modelIndex: configs["model_index.json"],
                                      tags: tags, architectures: architectures(from: config))
        let ggufVariant = ggufVariant ?? pickGGUFVariant(siblings: siblings)
        let ggufSummary = ggufHeader.map { GGUFModelSummary(header: $0) }
        let formats = detectFormats(siblings: siblings, libraryName: libraryName,
                                    config: config, tags: tags, repoOwner: reference.repoID.owner)
        // Core ML diffusion repos (apple/coreml-stable-diffusion-*) ship
        // either per-variant folders of compiled .mlmodelc trees or one zip
        // per variant. Pick the iPhone-appropriate variant up front so file
        // selection, memory estimates, and the runtime all agree.
        let diffusionVariant = modality == .imageGeneration
            ? pickCoreMLDiffusionVariant(siblings: siblings, repoName: reference.repoID.name)
            : nil
        let quantization = detectQuantization(config: config, tags: tags,
                                              ggufVariant: ggufVariant,
                                              repoName: reference.repoID.name)
        let parameters = safetensorsHeader?.parameterCount
            ?? (ggufSummary.map { $0.parameterCount }?.nilIfZero)
            ?? estimateParametersFromConfig(config)
            ?? estimateParametersFromName(reference.repoID.name)
        let context = config?.maxPositionEmbeddings
            ?? configs["generation_config.json"]?.maxPositionEmbeddings
            ?? ggufSummary?.contextLength
        var hints = architectureHints(from: config)
            ?? ggufHeader.map { ArchitectureHints(ggufMetadata: Self.ggufMetadataDictionary($0)) }
        if let variant = diffusionVariant {
            var h = hints ?? ArchitectureHints()
            h.diffusionResolution = variant.resolution
            hints = h
        }

        let required = selectRequiredFiles(siblings: siblings, ggufVariant: ggufVariant,
                                           formats: formats,
                                           diffusionVariant: diffusionVariant)
        let totalSize = required.reduce(Int64(0)) { $0 + $1.size }
        let weightMemory = estimateWeightMemory(parameters: parameters, quantization: quantization,
                                                requiredSize: required.isEmpty ? nil : totalSize)

        var metadata: [String: String] = [:]
        if let pipelineTag { metadata["pipeline_tag"] = pipelineTag }
        if let libraryName { metadata["library_name"] = libraryName }
        if let license = frontMatter?.license { metadata["license"] = license }
        if let modelType = config?.modelType { metadata["model_type"] = modelType }
        metadata["revision"] = revision
        if info.gated != nil { metadata["gated"] = "true" }
        if config?.requiresRemoteCode == true { metadata["requiresRemoteCode"] = "true" }
        if let header = safetensorsHeader {
            metadata["safetensors_dtypes"] = header.dtypes
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
        if let summary = ggufSummary {
            // Ground truth from the GGUF header itself: quantization scheme
            // from file_type, chat-template presence for the prompt builder.
            if let scheme = summary.quantization?.scheme, metadata["quantization"] == nil {
                metadata["quantization"] = scheme
            }
            if summary.chatTemplate != nil { metadata["chat_template"] = "gguf" }
            if let arch = summary.architecture { metadata["gguf_architecture"] = arch }
        }
        if let variant = diffusionVariant {
            metadata["diffusion_attention"] = variant.attention
            metadata["diffusion_form"] = variant.form == .archive ? "zip" : "folder"
            metadata["diffusion_palettized"] = variant.palettized ? "true" : "false"
            metadata["diffusion_resources_dir"] = variant.resourceDirectory
            if let resolution = variant.resolution {
                metadata["diffusion_resolution"] = String(resolution)
            }
        } else if modality == .imageGeneration, formats.contains(.coreml) == false {
            // Honest dead end: a diffusers-style repo (safetensors UNet)
            // cannot run until someone converts it to Core ML.
            metadata["unsupported_reason"] =
                "Needs Core ML conversion: this repository ships PyTorch/safetensors diffusion weights, not compiled .mlmodelc resources"
        }

        return ModelDescriptor(
            repoID: reference.repoID.description,
            name: reference.repoID.name,
            architecture: config?.architecture,
            modality: modality,
            parameterCount: parameters,
            quantization: quantization,
            formats: formats,
            totalDownloadSize: required.isEmpty ? nil : totalSize,
            requiredFiles: required,
            estimatedWeightMemory: weightMemory,
            estimatedRuntimeMemory: nil,
            supportedRuntimes: runtimes(for: formats, modality: modality,
                                        requiresRemoteCode: config?.requiresRemoteCode == true,
                                        hasRunnableDiffusionVariant: diffusionVariant != nil),
            contextLength: context,
            architectureHints: hints,
            metadata: metadata
        )
    }
}

private extension Int64 {
    /// Parameter counts of zero are useless — treat as missing.
    var nilIfZero: Int64? { self == 0 ? nil : self }
}
