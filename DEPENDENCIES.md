# Dependencies

Third-party dependencies pinned by this repository, with their licenses.

## llama.cpp

- **Version pin**: tag `v0.5.0`, commit `7fe450e19305b828c199d602c23a8337aaa1f03b` (published 2026-09-23).
- **License**: MIT — https://github.com/ggml-org/llama.cpp/blob/v0.5.0/LICENSE
- **Upstream**: https://github.com/ggml-org/llama.cpp

### Apple (iOS / macOS)

SwiftPM binary target `llama`, official xcframework from the upstream release
whose commit is exactly the v0.5.0 tag commit:

- URL: https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-xcframework.zip
- SHA-256 (via `swift package compute-checksum`): `1c306afe9fe68a90c4bdc74619d8558d6e0754f085deb105dd2d70293a9a964f`

Note: the `v0.5.0` GitHub release itself ships no xcframework asset; `b11146`
is the continuous-delivery release cut at the same commit
(`7fe450e19305b828c199d602c23a8337aaa1f03b`), so the Apple and Linux pins are
bit-identical source.

### Linux

Built from source by `scripts/build-llama-linux.sh`: clones tag `v0.5.0`
(depth 1) into `.deps/llama.cpp` (gitignored), builds shared libraries with
cmake (CPU only, `LLAMA_CURL=OFF`, `BUILD_SHARED_LIBS=ON`, Release, `-j2`),
and installs into `.deps/llama-install`. Package.swift links it only when
`LOCALLY_LLAMA=1` is set or the install dir exists; otherwise the GGUF runtime
honestly reports llama.cpp as not linked.

### Test model (not shipped)

`scripts/download-test-model.sh` fetches
`bartowski/SmolLM2-135M-Instruct-GGUF` (Q4_K_M) from Hugging Face into
`.deps/models` for the `LOCALLY_LIVE_LLAMA=1` live inference test. Apache 2.0
weights; never committed, never used in CI.

## MLX stack (Apple only, app target)

### mlx-swift-lm

- Version: 3.31.4 (exact; tag `3.31.4`)
- License: MIT
- Upstream: https://github.com/ml-explore/mlx-swift-lm (moved out of
  mlx-swift-examples in 2025)
- Products used: `MLXLLM`, `MLXLMCommon`
- Notes: pinned to 3.31.4 instead of the newer 3.32.3 because 3.32.x
  requires swift-tools 6.2 / Xcode 26, which the macos-15 CI image does
  not provide. 3.x decouples tokenizers behind the `TokenizerLoader`
  protocol, so we load the bundled swift-transformers tokenizer from the
  installed model directory with no network path (no `Downloader` is
  used; the HF hub is never touched at inference time).

### mlx-swift

- Version: 0.31.4 (exact; tag `0.31.4`, pulled transitively by
  mlx-swift-lm as `.upToNextMinor(from: "0.31.4")`; pinned explicitly so
  the app can link `MLX`/`MLXRandom` directly)
- License: MIT
- Upstream: https://github.com/ml-explore/mlx-swift
- Products used: `MLX`, `MLXRandom`
- Notes: memory controls are `MLX.Memory.memoryLimit` / `cacheLimit`
  (get/set) and `MLX.Memory.clearCache()`; the older
  `MLX.GPU.set(cacheLimit:)` forwards to these and is deprecated in
  0.31.4.

### swift-transformers

- Version: 1.3.4 (exact; tag `1.3.4`)
- License: Apache-2.0
- Upstream: https://github.com/huggingface/swift-transformers
- Products used: `Tokenizers`
- Notes: `AutoTokenizer.from(modelFolder:)` loads tokenizer.json +
  tokenizer_config.json from a local directory; chat templating goes
  through swift-jinja. Deployment target iOS 16, satisfied by our iOS 17
  floor.

### Binary-size notes

MLX ships Metal kernels compiled at build time and links Accelerate /
Metal statically into the app; expect roughly 15-30 MB added to the app
binary for the MLX stack (varies by architecture slice and dead-code
stripping). swift-transformers + swift-jinja are pure Swift and add
under 2 MB. Weights are never bundled — models are downloaded at
runtime into Application Support.
