#!/usr/bin/env bash
# Build llama.cpp (pinned tag v0.5.0) for Apple platforms as a local
# xcframework with an iOS Simulator slice. The upstream GitHub release for
# b11146 ships iOS-device and macOS slices only, which breaks
# `xcodebuild -destination 'platform=iOS Simulator'`; this script uses the
# upstream build-xcframework.sh to produce the slices we need, then leaves
# the result at .deps/llama-apple/llama.xcframework where Package.swift
# picks it up in place of the URL binary target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="v0.5.0"
SRC="$ROOT/.deps/llama.cpp"
OUT="$ROOT/.deps/llama-apple"

mkdir -p "$ROOT/.deps"

if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi

done_stamp="$OUT/.done"
if [ -f "$done_stamp" ] && [ -f "$OUT/llama.xcframework/Info.plist" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "llama.cpp $TAG already built at $OUT/llama.xcframework"
    exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# Build only what the iOS app actually links against: iOS device + simulator.
# macOS slices are unused by the iOS app and doubling them doubles CI time.
(cd "$SRC" && bash build-xcframework.sh ios-device ios-sim)

cp -R "$SRC/build-apple/llama.xcframework" "$OUT/llama.xcframework"
touch "$done_stamp"

echo "llama.cpp $TAG xcframework installed to $OUT/llama.xcframework"
xcodebuild -version
plutil -p "$OUT/llama.xcframework/Info.plist" | grep -E "CFBundlePackageType|SupportedPlatform|xcode" || true
