# Supported Models

What Locally can actually run today, by runtime. Everything not listed
here is reported honestly as unsupported in the app rather than faked.

## Text generation

- **MLX format** (Apple GPU, via mlx-swift-lm 3.31.4 `MLXLLM`): the
  architectures listed in `MLXRuntime.knownModelTypes` (llama, mistral,
  gemma 1–4, phi family, qwen2/qwen3 family, and more).
- **GGUF format** (llama.cpp v0.5.0): the architectures listed in
  `GGUFRuntime.knownArchitectures`.

## Vision-language (image understanding)

Served by `VLMRuntime` over MLXVLM (mlx-swift-lm 3.31.4), MLX format only,
Apple GPU only. Supported `model_type` values (from
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

Structured question answering over the active text backend (see
`Sources/LocallyRuntime/Decision`).
