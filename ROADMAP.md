# Roadmap

Twelve-week build-out (weeks 1–12, with a mid-plan performance pass
labelled 6b and week 12 split into 12a/12b hardening), completed
2026-10-02, followed by a final hardening pass. Per-week detail and
rationale live in DECISIONS.md; this file tracks status.

| Week | Scope | Status |
|------|-------|--------|
| 1 | Package skeleton, device profiler, benchmark, AI performance index, app shell (5 tabs, en+ko) | Done |
| 2 | HF client, repo-id/URL parsing, repository analyzer (config, safetensors headers, param estimation) | Done |
| 3 | Storage layer: filesystem layout, model registry, download manager core, path sanitizer | Done |
| 4 | Download resume/retry through the state-machine reducer, transport isolation | Done |
| 5 | MLX stack integration (mlx-swift-lm 3.31.4 pin), app wiring | Done |
| 6 | GGUF runtime on llama.cpp (pinned v0.5.0), GGUF parser with safety caps | Done |
| 6b | GGUF decode performance fix (sampler chain reuse, single actor hop per token, thread count) | Done — see PERFORMANCE.md |
| 7 | Concurrency hardening (`LockedState` for iOS 17), event stream contract, single terminal event | Done |
| 8 | VLM runtime over MLXVLM, pre-inference image downsampling | Done |
| 9 | Diffusion: Core ML (apple/ml-stable-diffusion) SD 1.x/2.x/XL variant selection and install | Done |
| 10 | Decision runtime: token log-prob scoring (llama.cpp backend) with validated generation fallback | Done |
| 11 | Video understanding via adaptive frame sampling over a VLM, map-reduce aggregation | Done |
| 12a | Hardening: vendored ml-stable-diffusion (SD3/T5 dropped), dependency-graph cleanup | Done |
| 12b | Failure-path and live end-to-end test suites, download-manager bug fixes | Done |
| Final | Thermal pacing in decode loops, security audit + SECURITY.md, release-build verification, docs | Done |

## Next steps

1. **On-device verification** (requires macOS + Xcode + a physical
   iPhone): run the Xcode scheme, exercise each playground, record real
   iPhone performance numbers into PERFORMANCE.md. MLX, MLXVLM, and
   Core ML paths are compiled out on Linux and have never run here.
2. **Multi-turn VLM chat** — VLM requests are currently single-turn
   (prior assistant turns are not replayed into the prompt;
   `VLMRuntime.swift`).
3. **Token scoring for MLX models** — `LlamaTokenScoringBackend` covers
   the GGUF runtime (`LlamaScoring.swift`, wired via
   `GGUFRuntime.makeScoringBackend()` in `DecisionRuntime`); MLX-backed
   decision questions still use the validated-generation fallback because
   MLXLMCommon's generation API does not expose per-token logits.
4. **Audio, speech, embedding, reranker runtimes** — the modalities are
   declared in the type system (`ModelModality`) but no runtime
   implements them; add only behind honest availability reporting.
