# Testing

The package test suite is split into unit tests (always run) and live-gated
integration tests (opt-in via environment variables). App-side SwiftUI
behavior is exercised on macOS CI via the Xcode scheme, not by SwiftPM.

## Unit tests

```bash
swift build -j 2
swift test -j 2
```

Swift 6 tools, runs on Linux and macOS. As of 2026-10-02 the full suite
executes 406 tests (15 skipped: the live-gated ones) covering the
analyzer, registry, download manager, runtime contracts, GGUF/llama
adapters, ZIP extraction, decision engine, vision/video planners, and the
thermal `GenerationPacer` — without touching the network or a real model.

### Failure-path suites

Dedicated failure-path coverage lives in:

- `Tests/LocallyStorageTests/DownloadFailurePathTests.swift` — resume
  corruption, ENOSPC mapping, retry clearing stale partials, redirect and
  progress-after-verifying handling
- `Tests/LocallyStorageTests/RegistryFailurePathTests.swift` — corrupted
  registry JSON, concurrent writes, delete-protection of loaded models
- `Tests/LocallyRuntimeTests/RuntimeFailurePathTests.swift` — run-before-
  load, context overflow, corrupted model files, cancellation
- `Tests/LocallyRuntimeTests/GGUFParserTests.swift` — hostile/truncated
  GGUF headers, limit enforcement

### Live end-to-end

`Tests/LocallyE2ETests/LocallyE2ETests.swift` (gated on
`LOCALLY_LIVE_E2E=1`, needs network + llama): HF URL → analyze →
compatibility → download → simulated relaunch → load → chat → benchmark →
unload → delete, printing per-stage timings.

**Clean rebuild after enum or generic changes.** The incremental cache has
been observed to leave stale object files after inserting a case into a
public enum or changing a generic signature; the symptom is a linker
"symbol not found" or a type-check error pointing at a removed member. If
that happens, `rm -rf .build` and rebuild — do not layer workarounds on
top.

## Live-gated tests

Live tests are skipped by default (`XCTSkip`) so CI and fresh clones stay
hermetic. Each gate is an environment variable; set it to `1` to opt in.

### `LOCALLY_LIVE_HF=1` — Hugging Face API + GGUF header parse

```bash
LOCALLY_LIVE_HF=1 swift test -j 2 --filter LiveHFCheckTests
```

Hits `huggingface.co` for a handful of public repos and exercises
`RepositoryAnalyzer.analyze(_:client:)` end to end, including the
Range-fetch of a chosen GGUF variant's header (params, layers, KV heads,
context, chat template). No token required for public repos.

### `LOCALLY_LIVE_DL=1` — Real download through `DownloadManager`

```bash
LOCALLY_LIVE_DL=1 swift test -j 2 --filter LiveDownloadIntegrationTests
```

Downloads a small real file into a temp directory, verifying redirect
handling, resume, and SHA-256 hashing against the live CDN.

### `LOCALLY_LIVE_LLAMA=1` — Real on-device inference + decision scoring

```bash
LOCALLY_LIVE_LLAMA=1 swift test -j 2 --filter "LiveLlamaTests|DecisionRuntimeTests"
```

Loads `.deps/models/SmolLM2-135M-Instruct-Q4_K_M.gguf` through the llama
bridge and runs a handful of text generations plus a three-question
decision pass over the token-scoring path. Asserts the single-terminal-
event invariant on every stream and that scored probabilities sum to 1.
`GenerationPacerTests` also uses this gate to assert the decode loop
awaits the pacer exactly once per generated token.

## llama.cpp setup

llama is optional. When the library is missing, runtimes report themselves
as not linked and every test that would need them skips.

- **Apple platforms** — the package manifest references the official
  `llama-b11146-xcframework.zip` from the pinned llama.cpp release
  (v0.5.0, commit `8edb2d29`). SwiftPM fetches and caches it on the first
  build; nothing else to do.
- **Linux** — run `scripts/build-llama-linux.sh` once. It clones the
  pinned tag into `.deps/llama.cpp`, builds a CPU-only shared library, and
  installs into `.deps/llama-install`. `Sources/CLlama/include` is a
  symlink to that install. The script is idempotent and CI caches the
  `.deps` directory by tag and arch.
- **Test model** — `scripts/download-test-model.sh` fetches the 80 MB
  SmolLM2 Q4_K_M into `.deps/models/`. Only needed for the
  `LOCALLY_LIVE_LLAMA` gate.

## What CI runs

`.github/workflows/ci.yml` runs two jobs:

- **linux** (`swift:6.1` container) — builds llama from the pinned tag,
  then `swift build` and `swift test` with `LOCALLY_LLAMA=1` (which makes
  the runtime report llama as linked without enabling the network-gated
  live tests).
- **macos** (`macos-15`) — generates the Xcode project with XcodeGen,
  lints the `*.xcstrings` catalogs and `Info.plist`, then runs
  `xcodebuild test` against the iPhone simulator scheme. That scheme
  builds the App target and runs the SwiftUI smoke tests; it does not run
  the SwiftPM suite.

CI does not set any `LOCALLY_LIVE_*` flag, so no live test runs there.

## Device-only items

Anything that needs Metal, the Neural Engine, `os_proc_available_memory`,
or a real memory warning is iOS-device-only and not covered by either CI
job. In particular:

- `MLXRuntime` (the whole type is `#if canImport(MLXLLM) && canImport(UIKit)`)
- `DeviceProfiler` GPU/ANE probes
- Memory-warning unload behavior
- `CompatibilityEngine` against real device benchmarks
- Tokenizer-load paths that only run through the app

For those, run the app on a device and exercise the playground manually.
The on-device benchmark on Home feeds `CompatibilityProvider` and survives
relaunch, so a fresh install shows estimated speeds until a first run.
