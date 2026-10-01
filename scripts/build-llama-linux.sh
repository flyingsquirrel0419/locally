#!/usr/bin/env bash
# Build llama.cpp shared libraries (CPU only) for Linux into .deps/llama-install.
# Pinned to a specific tag; see DEPENDENCIES.md. Idempotent: skips work that
# is already done. Use FORCE=1 to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="v0.5.0"
SRC="$ROOT/.deps/llama.cpp"
INSTALL="$ROOT/.deps/llama-install"
BUILD="$ROOT/.deps/llama-build"

mkdir -p "$ROOT/.deps"

if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi

# The CLlama systemLibrary target resolves headers relative to its own
# directory; give it a symlink to the install include dir (gitignored).
# Created before the early exit below because CI caches .deps but not
# this symlink.
if [ -d "$INSTALL/include" ]; then
    (cd "$ROOT/Sources/CLlama" && ln -sfn ../../.deps/llama-install/include include)
fi

done_stamp="$BUILD/.done"
if [ -f "$done_stamp" ] && [ -f "$INSTALL/lib/libllama.so" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "llama.cpp $TAG already built at $INSTALL"
    exit 0
fi

rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_APP=OFF \
    -DGGML_NATIVE=OFF \
    -DCMAKE_INSTALL_PREFIX="$INSTALL"
cmake --build "$BUILD" --config Release -j 2
cmake --install "$BUILD"
touch "$done_stamp"
(cd "$ROOT/Sources/CLlama" && ln -sfn ../../.deps/llama-install/include include)

echo "llama.cpp $TAG installed to $INSTALL"
ls -1 "$INSTALL/lib"
