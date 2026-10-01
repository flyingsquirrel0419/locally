# Locally

Locally is an iPhone app for running AI models entirely on-device: browse
Hugging Face models, check whether they fit your device, download them, and
run them locally. No cloud inference.

## Features and status

| Capability | Runtime | Status |
|---|---|---|
| Text generation (GGUF) | llama.cpp v0.5.0, CPU | **Verified on Linux** (live inference tests, release-build benchmarks — see PERFORMANCE.md) |
| Text generation (MLX) | mlx-swift-lm 3.31.4, Apple GPU | Implemented; needs on-device verification |
| Vision-language | MLXVLM, Apple GPU | Implemented; needs on-device verification. Single-turn only |
| Image generation | Core ML (vendored ml-stable-diffusion), SD 1.x/2.x/XL | Implemented; needs on-device verification |
| Video understanding | frame sampling over a VLM, map-reduce | Implemented; needs on-device verification |
| Decision (structured QA) | token log-prob scoring over the text backend | Implemented; llama.cpp scoring backend live-tested on Linux; MLX models use the validated-generation fallback |
| Video generation | — | **Unavailable** — honestly reported; no on-device model fits |
| Audio / speech / embedding / reranker | — | **Unavailable** — no runtimes implemented |
| `trust_remote_code` models | — | Refused by design (see SECURITY.md) |

The app never fakes capability: anything without a working backend reports
itself unsupported with a reason.

## Architecture

SwiftPM package (`Sources/`) with platform-independent modules —
`LocallyCore`, `LocallyDevice`, `LocallyHF`, `LocallyCompatibility`,
`LocallyStorage`, `LocallyRuntime` — plus a SwiftUI app target (`App/`,
Xcode only). The package builds and its tests pass on Linux. See
ARCHITECTURE.md for the module graph, request flow, event-stream contract,
memory/thermal policy, and persistence layout.

## Requirements

- iOS 17+ device for the app; Xcode 16+ to build it (macOS)
- Swift 6.1+ toolchain for the package (Linux or macOS)
- Hugging Face token optional (only needed for gated/private repos;
  Keychain-only, never logged — see SECURITY.md)

## Building

### Linux (package only)

```sh
swift build -j 2
swift test -j 2
```

llama.cpp is optional on Linux; to enable the GGUF runtime and live
inference tests:

```sh
scripts/build-llama-linux.sh        # pinned llama.cpp, CPU-only, into .deps/
scripts/download-test-model.sh      # 99 MB SmolLM2 GGUF for the live tests
swift build -j 2
LOCALLY_LIVE_LLAMA=1 swift test -j 2 --filter LiveLlamaTests
```

Live-gated tests (`LOCALLY_LIVE_HF`, `LOCALLY_LIVE_DL`,
`LOCALLY_LIVE_LLAMA`, `LOCALLY_LIVE_E2E`) are skipped by default; see
TESTING.md.

### iOS app (requires macOS + Xcode 16)

```sh
brew install xcodegen
xcodegen generate
open Locally.xcodeproj
# or: xcodebuild test -project Locally.xcodeproj -scheme Locally \
#       -destination 'platform=iOS Simulator,name=iPhone 16'
```

Note: the simulator has no Metal device; MLX/VLM/diffusion runtimes report
themselves unavailable there. Use a physical device for anything GPU.

## Supported models

See SUPPORTED_MODELS.md for the exact architecture lists per runtime and
the honest unsupported list.

## Known limitations

- One large model loaded at a time (loading a new model unloads the old).
- VLM requests are single-turn.
- iPhone performance is not yet measured; the only numbers on record are a
  Linux x86 CPU baseline (PERFORMANCE.md).
- Decision questions on MLX-backed models use the validated-generation
  fallback (the llama.cpp scoring backend covers GGUF; MLXLMCommon does
  not expose per-token logits).
- Memory-pressure race: a model that grows after the load-time budget
  check can still trigger jetsam before the policy observer reacts
  (see SECURITY.md, residual risks).

## Layout

- `Package.swift`, `Sources/`, `Tests/` — the SwiftPM package (Linux-safe)
- `App/` — the SwiftUI app (Xcode only), `project.yml` — XcodeGen spec
- `Vendor/StableDiffusion` — vendored Core ML pipeline (see its VENDORED.md)
- `DECISIONS.md` — architectural decision log
- `.github/workflows/ci.yml` — Linux + macOS CI
