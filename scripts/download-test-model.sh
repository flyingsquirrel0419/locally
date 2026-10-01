#!/usr/bin/env bash
# Download a tiny instruct GGUF for the live inference test into .deps/models.
# Only used when LOCALLY_LIVE_LLAMA=1; never in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.deps/models"
FILE="SmolLM2-135M-Instruct-Q4_K_M.gguf"
URL="https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/$FILE"

mkdir -p "$DIR"
if [ ! -f "$DIR/$FILE" ]; then
    curl -fL --retry 3 -o "$DIR/$FILE" "$URL"
fi
echo "$DIR/$FILE"
