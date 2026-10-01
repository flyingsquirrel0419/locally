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
