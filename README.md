# Locally

Locally is an iPhone app for running AI models entirely on-device: browse
Hugging Face models, check whether they fit your device, download them, and
run them locally. No cloud inference.

## Status

**Week 1 — foundation only.** What exists today:

- SwiftPM package with six library targets:
  `LocallyCore` (model types, errors, logging), `LocallyDevice` (device
  profiler, memory budget, thermal monitor, benchmark, AI performance
  index), plus `LocallyHF`, `LocallyCompatibility`, `LocallyStorage`,
  `LocallyRuntime` with minimal real foundations for later weeks.
- iOS app shell (SwiftUI, iOS 17+): five tabs, device profile on Home,
  time-boxed benchmark with a relative 0–1000 AI score, en + ko
  localization.
- No model download, no inference, no HF API client yet. Screens say so.

## Building

### Linux (package only)

```sh
swift build -j 2
swift test -j 2
```

### iOS app (requires macOS + Xcode 16)

```sh
brew install xcodegen
xcodegen generate
open Locally.xcodeproj
# or: xcodebuild test -project Locally.xcodeproj -scheme Locally \
#       -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Layout

- `Package.swift`, `Sources/`, `Tests/` — the SwiftPM package (Linux-safe)
- `App/` — the SwiftUI app (Xcode only), `project.yml` — XcodeGen spec
- `Docs/` — design docs; `DECISIONS.md` — architectural decision log
- `.github/workflows/ci.yml` — Linux + macOS CI

## Notes

- The AI performance index is a **relative internal score**, not a
  scientific benchmark; see `DECISIONS.md`.
- HF tokens, when supported, will live in the Keychain only. Never logged.
