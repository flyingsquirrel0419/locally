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
