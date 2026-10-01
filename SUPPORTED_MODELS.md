# Supported Models

What Locally can actually run today, by runtime. Everything not listed
here is reported honestly as unsupported in the app rather than faked.

## Text generation

- **MLX format** (Apple GPU, via mlx-swift-lm 3.31.4 `MLXLLM`): the 58
  `model_type` values listed in `MLXRuntime.knownModelTypes` (llama,
  mistral/mistral3, gemma 1–4, phi family, qwen2/qwen3/qwen3.5 families,
  deepseek_v3, glm4 family, and more).
- **GGUF format** (llama.cpp v0.5.0, CPU): the architectures listed in
  `GGUFRuntime.knownArchitectures` — the full llama.cpp `LLM_ARCH_NAMES`
  set for the pinned tag (~150 entries: llama, gemma, qwen, phi, mistral,
  deepseek, glm, bert/embedding variants, and others). Note that several
  of these (bert-family, `llama-embed`) are embedding architectures that
  llama.cpp can load, but Locally exposes only the text-generation path
  today — embeddings are not surfaced as a feature.

## Vision-language (image understanding)

Served by `VLMRuntime` over MLXVLM (mlx-swift-lm 3.31.4), MLX format only,
Apple GPU only. Supported `model_type` values (18, from
`VLMTypeRegistry.knownTypes`, which mirrors MLXVLM's own registry):

| model_type | Multi-image | Video frames |
|---|---|---|
| paligemma | no | no |
| qwen2_vl | yes | yes |
| qwen2_5_vl | yes | yes |
| qwen3_vl | yes | yes |
| qwen3_5, qwen3_5_moe | yes | yes |
| idefics3 | yes | no |
| gemma3 | yes | no |
| gemma4, gemma4_unified | yes | yes |
| smolvlm | yes | yes |
| fastvlm, llava_qwen2 | no | no |
| pixtral, mistral3 | yes | no |
| lfm2_vl, lfm2-vl | yes | no |
| glm_ocr | no | no |

Images are downsampled before inference (aspect-preserving, multiple of the
model's patch factor, hard-capped at 1536 px on the long edge) so a
full-resolution phone photo never decodes into memory. Multi-image models
accept up to 4 images per request.

**Known limitation:** VLM requests are single-turn — prior assistant turns
in a chat are not replayed into the prompt.

## Image generation (diffusion)

Core ML only, via a vendored copy of apple/ml-stable-diffusion (commit
`ea2805dc`, SD3/T5 sources removed — see Vendor/StableDiffusion/VENDORED.md).
The analyzer offers a diffusion runtime only for repos in Apple's
`coreml-stable-diffusion-*` layout: Stable Diffusion 1.x, 2.x, and XL
variants, with `split_einsum` attention strongly preferred (required for
Neural Engine execution) and palettized variants preferred for size.
Non-Core ML diffusers repos (safetensors/checkpoint layouts) are reported
unsupported — no on-device diffusers runtime exists.

## Video understanding

Video understanding uses **frame sampling**, not a native video encoder: a
planner picks 8/16/32 frames (adaptive to duration, thermal state, and low
power mode; reduced under pressure, refused at critical thermal), the
sampled frames are analyzed in batches by an active vision-language model
with timestamp labels, and the per-batch answers are aggregated
(map-reduce) into a final answer. In "Important moments" mode the model
cites timestamps (`[t=12.4s]`), which are parsed into tappable ranges in
the playground.

Requirements: a supported VLM from the table above, MLX format, Apple GPU.

## Video generation

Not available. The runtime interface exists
(`VideoGeneratingRuntime` in LocallyRuntime) and the registered runtime
reports honestly: video generation is experimental and not available on
iPhone yet — no text-to-video model fits the on-device memory and compute
budget today.

## Decision

Structured question answering (choice/boolean/probability/score/ranking)
over the active text backend (see `Sources/LocallyRuntime/Decision`).
GGUF models are scored by token log-probabilities via
`LlamaTokenScoringBackend` (`LlamaScoring.swift`, wired through
`GGUFRuntime.makeScoringBackend()`); backends without a scoring
implementation (MLX today — MLXLMCommon does not expose per-token logits)
use a validated single-generation fallback.

## Explicitly unsupported

- **`trust_remote_code` models** — detected via `auto_map` / custom
  quantization config and refused. Repository code is never executed.
- **Non-Core ML diffusion** (raw diffusers/safetensors).
- **ONNX** models — no ONNX runtime is integrated.
- **Audio / speech recognition / speech synthesis** — modalities are
  declared in the type system (`ModelModality.audio`, `.speechRecognition`,
  `.speechSynthesis`) but no audio runtime is implemented; the router
  reports them unavailable.
- **Embedding / reranker as features** — no embedding or reranker runtime
  is wired, even where llama.cpp could load the architecture.
