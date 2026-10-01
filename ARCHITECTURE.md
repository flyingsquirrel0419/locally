# Architecture

Locally is a SwiftPM package of platform-independent modules plus a SwiftUI
app target. All logic that does not need an Apple framework lives in the
package and builds and tests on Linux; Apple-only code is either in `App/`
or behind `#if canImport(...)` with a Linux fallback.

## Module graph

```
                 ┌────────────────────────────┐
                 │          App/              │  SwiftUI, iOS 17+, Xcode only
                 │  Features/ Runtimes/       │  MLX, MLXVLM, Diffusion (Core ML),
                 │  Infrastructure/           │  ResourcePolicyObserver, registry
                 └───────┬────────────────────┘
                         │ depends on package products
   ┌─────────────┬───────┼───────────┬─────────────────┐
   ▼             ▼       ▼           ▼                 ▼
LocallyHF   LocallyStorage  LocallyRuntime      LocallyDevice
(HF API,    (downloads,     (router, runtimes,  (profiler, benchmark,
 analyzer,   registry, ZIP,  GGUF/llama bridge,  thermal, resource
 token store) resume, sha256) decision, video)   policy brain)
   └─────────────┴───────┴───────┴────┴─────────────────┘
                         ▼
                   LocallyCore
        (types, AIEvent, errors, Log, GGUF parser,
         RedirectPolicy, PathSanitizer-free primitives)

LocallyCompatibility sits between HF/Storage and Runtime:
(memory estimation + compatibility ratings, depends on
LocallyCore/LocallyHF/LocallyDevice only)
```

Dependency direction is strictly downward; `LocallyCore` depends on
nothing else in the package.

## Request flow

```
HF URL / repo id
   │  HFRepoReference, RepoID (LocallyHF)
   ▼
RepositoryAnalyzer ── config.json / README / GGUF header (Range fetch)
   │  → ModelDescriptor: modality, formats, architecture, parameter
   │    estimate, required files, requiresRemoteCode flag
   ▼
CompatibilityEngine ── MemoryEstimator (weights + KV cache + activations
   │                     + vision encoder + safety margin) vs device budget
   │  → CompatibilityRating: supported / risky / unsupported(reason)
   ▼
ModelInstallService ── DownloadJob → DownloadManager (state machine,
   │                     resume, free-space preflight, sha256 verify,
   │                     ZIP install for Core ML .mlmodelc)
   ▼
ModelRegistry ── JSON persistence of installed models
   │  → InstalledModel on disk under Application Support
   ▼
RuntimeRouter ── picks the first runtime that supports the descriptor on
   │              this device (GGUF → MLX → VLM → Diffusion → …)
   ▼
AIRuntime.run(request) → AsyncThrowingStream<AIEvent>
```

## Event stream contract

Every runtime returns `AsyncThrowingStream<AIEvent, Error>` with the same
contract (`Sources/LocallyCore/AIEvent.swift`):

- zero or more progress events: `.started`, `.preparing(phase)`,
  `.progress`, `.token`, `.partialText`, `.image`, `.decision`,
  `.metadata`
- **exactly one terminal event**: `.completed(result)` or
  `.failed(error)` — then the stream finishes. Cancellation is delivered
  as `.failed(.cancelled)`. `TerminalEventInvariant` in the test suite
  asserts this on every live stream.

## Memory and thermal policy

- `MemoryBudget.safeAIBudget` (`LocallyDevice`) is the single budget
  heuristic used by the compatibility engine, the registry's load-time
  refusal, and the MLX allocator bound.
- `ResourcePolicy` (`LocallyDevice`) is a pure decision function over
  (thermal state, low-power mode, memory pressure, current activity) →
  actions: stop generation, unload idle model, clear caches, throttle
  generation, reduce video frame budget, refuse heavy inference.
- `ResourcePolicyObserver` (`App/Infrastructure`) is the iOS shell that
  feeds it real OS signals and executes the actions.
- Thermal throttling reaches decode loops via `GenerationPacer`
  (`LocallyRuntime/GenerationPacer.swift`): GGUF/MLX/VLM await
  `pacer.pace()` between tokens; the app injects
  `PolicyGenerationPacer`, which reads the current inter-token delay
  from the observer live (40 ms/token at "serious" thermal).

## Persistence layout

```
Application Support/
  Models/<org>_<name>/<revision>/…        model files (sanitized paths)
  Models/<org>_<name>/<revision>/metadata.json
  Downloads/…                             part files + resume data
  registry.json                           ModelRegistry (installed models)
HF token: Keychain only (never on disk). Benchmark snapshot: UserDefaults
(non-sensitive performance data only).
```

## Concurrency model

- Swift 6 strict concurrency: value types are `Sendable`; mutable shared
  state lives in actors (`DownloadManager`, `ModelRegistry`,
  `HFClient`, runtime load-state actors) or `LockedState<Value>`
  (NSLock box, replaces `Synchronization.Mutex` which needs iOS 18).
- Dependency injection at boundaries: `HTTPTransport`,
  `DownloadTransport`, `TokenStore`, free-space provider, and the
  generation pacer are all injectable, which is what makes the suite
  hermetic on Linux.
- One large model loaded at a time: `RuntimeRegistry` unloads the
  previous runtime before loading a new one.
