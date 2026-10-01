# Decisions

## 2026-10-01 — Safe AI memory budget heuristic

An iOS app realistically keeps ~50–65% of physical RAM as usable working
set before jetsam terminates it (observed across A-series devices; Apple
documents jetsam but not a fixed ratio). Devices with the
`com.apple.developer.kernel.increased-memory-limit` entitlement may exceed
this. We take **55% of physical RAM** as the baseline, clamp to the current
available-memory estimate, and further clamp to `os_proc_available_memory()`
on platforms where it exists (loaded dynamically to keep SDK surface
minimal). Conservative beats optimistic: an underestimated budget produces
a false "incompatible" rating, an overestimated one produces a crash.

## 2026-10-01 — AIPerformanceIndex is relative, not scientific

The 0–1000 score normalizes measured CPU Float32 matmul GFLOPS (192³,
i-k-j loop order), memcpy-style bandwidth (64 MB buffers), and Metal FMA
throughput against an arbitrary reference baseline approximating an
A14-class device (10 CPU GFLOPS, 30 GB/s memory, 500 Metal GFLOPS).
Weights: CPU 40% / memory 30% / GPU 30%, redistributed to 55/45 when Metal
is unavailable. A logarithmic memory bonus (log2(GB+1)/log2(9), clamped to
0.25–1.5) rewards larger RAM without letting 128 GB desktops explode the
scale. Scores are comparable only within the same benchmark version; the
UI labels it as a relative internal score.

## 2026-10-01 — Benchmark is time-boxed and cancellable

Each stage (CPU ~1.5 s, memory ~1 s, Metal ~1.5 s) runs on its own
sub-deadline inside a 4.5 s hard budget, checks `Task.isCancelled` between
iterations, and reports nil for any stage that could not run. Tests assert
the total wall time stays under 5 s.

## 2026-10-01 — Linux fallbacks keep platform logic testable

All platform-independent logic lives in the package and must build and
test on Linux. Apple-only APIs (UIKit battery, Metal,
`os_proc_available_memory`, thermal notifications) sit behind
`#if canImport(...)` / `#if os(...)`. Linux fallbacks are honest:
`metalAvailable = false`, thermal stream emits `.nominal` once and stays
open (polling-free), Neural Engine presence is reported as *unknown*, and
`ProcessInfo.ThermalState` / low-power mode are not read on Linux because
swift-corelibs-foundation lacks them.

## 2026-10-01 — Repo id and path validation without Regex

`Regex` is not Sendable under Swift 6 strict concurrency on Linux, so
`RepoID` validates components with plain character checks and
`PathSanitizer` splits with `omittingEmptySubsequences: false` so that
`a//b` and trailing slashes are rejected rather than silently collapsed.
Both reject `..`, absolute paths, backslashes, and NUL before any path
reaches disk.

## 2026-10-01 — Logging never carries secrets

`Log` wraps OSLog on Apple platforms (public privacy annotations) and
stderr on Linux. It has no API that accepts tokens or user content, and
the project rule is that model file bytes, HF tokens, and prompts are
never passed to it.

## Week 2

### 2026-10-01 — Safetensors header counts need a packed-bits hint

MLX 4-bit repos store quantized weights as packed `U32` tensors whose
`shape` reflects packed columns ([rows, cols/8] for 4-bit), so a naive
dtype×shape sum undercounts (77M reported for a 0.5B model). The analyzer
passes the config-declared quantization bits into the header parser, which
expands `.weight` entries of dtype U32/I32 by 32/bits. Headers are summed
across all top-level safetensors shards (subdirectory shards like diffusion
unet/vae are not summed into a single count — diffusion repos report no
global parameter count from headers).

### 2026-10-01 — GGUF default variant is Q4_K_M, else smallest ≥4-bit

Q4_K_M is the de-facto best quality/size tradeoff in llama.cpp quant sets.
When absent, the analyzer picks the smallest file whose parsed quant is
≥4 bits (below that, quality degrades sharply), falling back to the first
listed GGUF. All other quants are excluded from `requiredFiles`.

### 2026-10-01 — HF access is HTTPS-only and token-optional

HFClient refuses non-huggingface.co / non-hf.co hosts when the default API
base is in use (tests may inject a different base via the mock transport,
which bypasses URL validation). The Authorization header is attached only
when a token exists — public repos work unauthenticated. The token lives in
the Keychain (AfterFirstUnlockThisDeviceOnly); a regression test asserts
LocallyError messages never carry it.

### 2026-10-01 — trust_remote_code models analyze but never run

Configs with `auto_map` are treated as data: the descriptor records
`requiresRemoteCode=true` in metadata and reports no supported runtimes.
Nothing from a repository is ever executed.

## Week 3

## 2026-10-01 — Storage preflight overhead model is 1.0x + headroom

Completed files are installed by rename within the same volume, so no
temporary copy of the payload exists at install time. The preflight requires
`remaining + max(512 MB, 5% of file size)` free; the headroom covers resume
data, jobs.json churn, and iOS snapshot overhead. Free space is probed via
`volumeAvailableCapacityForImportantUsage` on Apple platforms; on Linux
corelibs lacks the key so the default provider returns `.max` (treated as
"unknown — proceed"), and the manager treats `.max` as a skip. The check
re-runs before every file, not once per job, because other apps can consume
space mid-job.

## 2026-10-01 — Resume data lives in files, URLs live in memory

URLSession resume blobs are opaque and can be large; they are written to
`Downloads/resume/<jobID>/<index>.resume` and only the filename is persisted
in jobs.json. Remote URLs are *not* persisted at all: the manager keeps them
in an in-memory registry keyed by job id, and after relaunch the app must
call `registerSources(_:for:)` before resuming. This keeps bearer tokens and
signed URLs out of the on-disk store by construction (the auth header itself
is injected at request time via `authHeaderProvider`, never stored).

## 2026-10-01 — SHA-256 without swift-crypto

CryptoKit under `canImport(CryptoKit)`; a ~60-line pure-Swift streaming
SHA-256 (FIPS 180-4) covers Linux, tested against the empty string, "abc",
a multi-block padding-boundary vector, and a 1 MB pattern whose reference
digest came from `sha256sum`. swift-crypto is deliberately not a dependency
so the package has zero external dependencies.

## 2026-10-01 — Transport protocol isolates URLSession quirks

`DownloadTransport` (start/pause/cancel + AsyncStream events) has three
implementations: `URLSessionBackgroundTransport` (iOS background session,
identifier `me.teamwicked.locally.downloads`, relaunch reattach via
`taskDescription`), `FoundationURLSessionTransport` (delegate-based
downloadTask; works with swift-corelibs-foundation which lacks
`URLSession.bytes(for:)`), and a mock for tests. The Foundation transport
has no resumeData concept — `pause` cancels and resume falls back to an
HTTP `Range` header from the part-file size, which the mock emulates.
All requests send `Accept-Encoding: identity` because gzip transcoding
breaks byte-exact size and sha256 verification (observed live: HEAD on HF
resolve endpoints omits Content-Length when compressed).

## 2026-10-01 — Queue pump is serialized; policy pauses are managed states

`schedule()` coalesces concurrent pumps through a `pumping`/`pumpAgain`
flag pair so retry, resume, and completion events cannot double-start a
file; `startFile` re-reads the store and bails if the file left `.queued`.
Automatic retry is capped at 3 with injected-clock exponential backoff
(1/2/4 s), and 401/403 (`HTTPStatusError`) are never retried. The
"only while charging" policy pauses via the same code path as user pause,
so resume data is captured identically.

## Week 4

### 2026-10-01 — Resume re-queues instead of jumping to downloading

`DownloadManager.resume()` previously set the file to `.downloading`
directly, bypassing the reducer and the serialized queue pump. The reducer
now maps `(paused, .resume) → .queued`, so `schedule()` owns the single
start path and the resumed file competes for slots fairly with queued work.
Progress is reset to 0 at re-queue because byte progress is recomputed
from the part file on the next start.

### 2026-10-01 — Redirect policy is a pure function, host matching is exact

All redirect auth-stripping funnels through
`RedirectPolicy.sanitize(request:original:)` — a pure, testable function
returning nil (refuse) for non-HTTPS targets and stripping `Authorization`
unless the target host exactly equals or is a true subdomain of an allowed
HF host (`huggingface.co`, `hf.co`). Suffix matching without the dot
(`hasSuffix("huggingface.co")`) accepted `evilhuggingface.co`; the
lookalike cases are pinned by tests. Every URLSession transport (HFClient,
Foundation download, iOS background download) installs a
`willPerformHTTPRedirection` delegate calling the same function.

### 2026-10-01 — Free space on Linux comes from statvfs

swift-corelibs-foundation lacks `volumeAvailableCapacityForImportantUsage`,
so the Linux free-space default was `.max` ("unknown — proceed"). The
provider now calls `statvfs` (`f_bavail × f_frsize`, the unprivileged
number) on Linux via Glibc, keeping the Apple key on Apple platforms. The
manager still treats `.max` as skip, which now only occurs when statvfs
itself fails.

### 2026-10-01 — Registry state sits in a Mutex so reads are nonisolated

`ModelRegistry` is an actor (mutations serialize), but its model map lives
in a `Mutex<[String: InstalledModel]>`, so `list()`, `get(id:)`,
`recentModels(limit:)`, and `storageSummary()` are nonisolated synchronous
reads. SwiftUI view models and Home polling read without `await`, and tests
avoid `await`-in-autoclosure pitfalls (XCTUnwrap et al. cannot wrap an
`await` expression). Persistence stays actor-isolated.

### 2026-10-01 — Revision is pinned and "/" is escaped in resolve URLs

The analyzer records the commit sha in descriptor metadata; the Add Model
flow pins the install to that sha so users get exactly what was analyzed
(branch `main` moves under you). HF resolve URLs keep slashes only in the
file path, not the revision: the revision is escaped with `urlPathAllowed`
minus `/` so `refs/pr/7` becomes `refs%2Fpr%2F7` rather than an extra path
segment.

### 2026-10-01 — directorySize skips directory entries; summary has slack

Linux reports ~4096 bytes per directory entry, which polluted storage
totals, so `directorySize` counts only regular files. The registry writes
a per-model `metadata.json` beside the weights, so `sizeOnDisk` recomputed
at registration includes it; tests assert bounds rather than exact byte
equality to allow the metadata overhead.

### 2026-10-01 — Live Week-4 verification runs as a standalone script

The end-to-end live check (analyze → install → registry → sha256) needs
both LocallyHF and LocallyStorage, and no existing test target depends on
both — adding one would mean editing Package.swift, which the concurrent
runtime worker owns. The check is therefore a standalone scratchpad script
compiled against the built modules (`-I .build/debug/Modules`) and run
once with `LOCALLY_LIVE_DL=1`, not a test-target addition.

### 2026-10-01 — Reconcile flags and reports, never silently deletes

Launch reconcile marks models whose files vanished with `hasMissingFiles`
(UI shows a warning and disables Run) and reports orphan directories in
`ReconcileReport.orphanDirectories` without deleting them — orphan cleanup
is a user decision, since an orphan may be a model the registry lost track
of, not garbage.

### 2026-10-01 — Linux live runs cap download concurrency at 1

swift-corelibs-foundation's `_HTTPURLProtocol.configureEasyHandle` fatals
with `libcurl.Easy Code=43` when two download tasks on the same session
start concurrently (reproduced deterministically with the default
`concurrentFileLimit: 2` on Swift 6.1.2/Linux; each file alone and
sequential execution complete fine). This is a platform bug in corelibs'
curl multi handling, not in the package — the manager's own queue logic
behaves identically at limit 1 and 2. Live verification scripts therefore
pass `concurrentFileLimit: 1` on Linux; the iOS background transport
(UIURLSession background session) is unaffected. Production default stays
2, since the shipping platform is iOS.

## Week 6

### 2026-10-01 — GGUF runtime on llama.cpp, pinned to the v0.5.0 commit

**Pin.** llama.cpp is pinned to tag `v0.5.0` (commit
`7fe450e19305b828c199d602c23a8337aaa1f03b`, 2026-09-23). The v0.5.0 GitHub
release ships no xcframework asset; continuous-delivery release `b11146` is
cut at exactly that commit, so the Apple binary target uses
`llama-b11146-xcframework.zip` and both platforms run bit-identical source.
Checksum is recorded in DEPENDENCIES.md and verified by SwiftPM on fetch.

**Linux link is opt-in at manifest time.** Package.swift adds the
`CLlama`/`LocallyLlama` targets only when `LOCALLY_LLAMA=1` or
`.deps/llama-install/include/llama.h` exists, evaluated from an absolute
path anchored at `#filePath` — relative paths in the manifest resolve
against an unreliable CWD and the result is cached in
`~/.cache/org.swift.swiftpm/manifests` (a stale cache once masked a broken
check; clear it when debugging manifest conditionals). Plain
`swift build` on Linux without llama still succeeds, and `GGUFRuntime`
honestly reports "llama.cpp is not linked into this build".

**Header delivery via symlink.** The CLlama systemLibrary target keeps its
modulemap at the target root and a gitignored symlink
`Sources/CLlama/include -> ../../.deps/llama-install/include`, created (and
re-created on every run, before the early exit) by
`scripts/build-llama-linux.sh`. This avoids `-I` unsafeFlags entirely, which
matter because cSettings do not propagate to dependent targets (the test
target compiles bridge sources transitively).

**C API surface.** The bridge uses the current v0.5.0 API:
`llama_model_load_from_file`, `llama_init_from_model`,
`llama_model_get_vocab`, `llama_chat_apply_template` (two-pass),
`llama_sampler_chain_*` (top-k → top-p → temp → dist; greedy when temp ≤ 0),
`llama_memory_seq_pos_max` for used-context accounting. Deprecated entry
points (`llama_load_model_from_file`, `llama_new_context_with_model`,
`llama_get_kv_cache_*`) are not used. GPU offload is `-1` (all layers) on
Apple where the xcframework includes Metal, `0` on the CPU-only Linux build.

**Chat templates: three tiers.** Rendering prefers (1) llama.cpp's own
`llama_chat_apply_template` with the model's embedded template, then (2) a
small Swift renderer for the common Jinja subset (a single
`{% for message in messages %}` loop with `if/else` branches on role and
`add_generation_prompt`), then (3) a ChatML fallback. The Swift renderer
returns nil rather than guessing when the template uses constructs outside
the subset (multiple loops, filters, macros); depth-aware if/endif scanning
handles nested conditionals.

**Streaming is UTF-8 safe.** llama token pieces can split multi-byte
sequences across tokens; `PieceAssembler` buffers raw bytes and emits only
the longest valid-UTF-8 prefix that does not end inside a multibyte
sequence, flushing the remainder at end of stream. Cancellation is polled
via `Task.isCancelled` once per generated token and tears down the context
before finishing the stream.

**Context overflow policy.** If the rendered prompt alone fills the window,
inference fails with a clear error; otherwise the generation budget is
truncated to `min(maxTokens, nCtx - promptTokens)` rather than silently
shifting the KV cache, so early turns are never dropped without the caller
knowing.

**GGUFParser treats files as hostile.** All reads are bounds-checked, no
mmap; string length ≤ 16 MB, array length ≤ 10 M, tensor/KV counts ≤ 1 M,
header ≤ 256 MB. Fixed-size array element counts are checked against
remaining bytes *before* allocation so a forged count cannot OOM. Bool
bytes > 1 and nested arrays are rejected. Tests truncate a valid file at
every byte offset and assert a thrown error, never a crash.

**Playground is honest by construction.** Non-text modalities render a
"Not yet supported" state; an unroutable model shows the router's
unsupported reason; a risky rating shows the warning and requires an
explicit "Try Anyway". The metrics footer displays only values measured by
the runtime (load time, TTFT, tok/s, token count) — nil renders as "–".

## Week 7

### 2026-10-01 — LockedState replaces Synchronization.Mutex for iOS 17

`Mutex` (Swift 6 Synchronization) requires iOS 18/macOS 15; the package
deploys to iOS 17/macOS 14, so the iOS build failed at link time. A small
`LockedState<Value>` (NSLock, `@unchecked Sendable`, `withLock`) in
LocallyCore replaces every usage — registry state, the URLSession
transport's task map, and test helpers. Same call shape, no behavior
change, no availability constraint.

### 2026-10-01 — Compatibility rating bands vs. safe budget

The report's rating compares the memory HIGH estimate against the device's
safe working-set budget (55% of physical RAM, clamped to available):
excellent < 0.45, good < 0.70, usable < 0.95, risky < 1.15, unsupported ≥ 1.15
(plus hard blockers: requiresRemoteCode, unknown modality, no runtime,
insufficient free storage). We rate on the high estimate because a crash
under load costs more than a false caution. Real consequences on the
fixture matrix: an 8B 4-bit model (~6.0–6.5 GB total) is unsupported on
an 8 GB iPhone (budget ~4.7 GB) but usable on 12 GB; 8B fp16 is
unsupported everywhere below 32 GB; 0.5B 4-bit is excellent from 6 GB up.
This matches field behavior of llama.cpp/MLX on A17-class hardware, where
an 8B quant at 8K context survives only on 12 GB devices with headroom to
spare.

### 2026-10-01 — Speed estimates come from data, never from guesses

Source order: (a) InferenceMetadata samples recorded by this device for
this model → `.measured(min…max)`; (b) the device benchmark's measured
memory GB/s ÷ weight bytes read per token, scaled by a 0.5–0.8 efficiency
band → `.estimated`; (c) otherwise `.unknown`. The UI labels all three
honestly. No model database, no marketing numbers, no fabricated tok/s.

### 2026-10-01 — Memory estimate is a range with a breakdown, plus margin

Weights prefer real download bytes over params × bits/8 (+3–10% quant
group overhead). KV cache = 2 × layers × kvHeads × headDim × context ×
dtypeBytes (2 B fp16 default), capped by the sliding window when the
architecture declares one. Activations ≈ vocab logits + 64 hidden-sized
scratch buffers. Per-runtime overhead constants are documented in
MemoryEstimator (MLX 200–400 MB, llama.cpp 150–300 MB, CoreML 250–500 MB,
diffusion 400–800 MB, video 0.5–1 GB). VLMs add the vision encoder tower
(config-derived params × 2 B + image buffer); diffusion adds
latent/VAE/UNet buffers at 1024²; video adds frames × frame buffers.
A 10–15% safety margin sits on top. Unknown inputs widen the range and
drop confidence to .low — never silently zero.
