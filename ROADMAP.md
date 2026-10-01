# Roadmap

Twelve-week build-out, completed 2026-10-02, plus the final hardening pass.
Per-week detail and rationale live in DECISIONS.md; this file tracks status.

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
| 10 | Decision runtime: token log-prob scoring with validated generation fallback | Done |
| 11 | Video understanding via adaptive frame sampling over a VLM, map-reduce aggregation | Done |
| 12a | Hardening: vendored ml-stable-diffusion (SD3/T5 dropped), dependency-graph cleanup | Done |
| 12b | Failure-path and live end-to-end test suites, download-manager bug fixes | Done |
| 13 | Final pass: thermal pacing in decode loops, security audit + SECURITY.md, release-build verification, docs | Done (this pass) |

## Next steps

1. **On-device verification** (requires macOS + Xcode + a physical
   iPhone): run the Xcode scheme, exercise each playground, record real
   iPhone performance numbers into PERFORMANCE.md. MLX, MLXVLM, and
   Core ML paths are compiled out on Linux and have never run here.
2. **Token-scoring backend for llama.cpp** — `TokenScoringBackend`
   currently has no llama implementation; decision questions on GGUF
   models use the validated-generation fallback until llama logits are
   bridged (`LlamaBridge`).
3. **GGUF architecture hints in the analyzer** —
   `ArchitectureHints(ggufMetadata:)` exists but is not yet called from
   the analyzer/registry path (needs a Range-fetch of the GGUF header).
4. **Benchmark → compatibility wiring** — `CompatibilityProvider` reads
   the persisted benchmark snapshot; verify the Home benchmark writes it
   on device.
5. **Multi-turn VLM chat** — VLM requests are currently single-turn
   (prior assistant turns are not replayed).
6. Audio, speech, embedding, and reranker modalities are declared in the
   type system but have no runtimes; add only behind honest availability
   reporting.
