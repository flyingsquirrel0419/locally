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
