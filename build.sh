#!/usr/bin/env bash
# build.sh — build WAGram tweak (normal device install)
set -euo pipefail

cd "$(dirname "$0")"

echo "[WAGram] Preparing embedded FLEX..."
FLEX_DIR="modules/FLEXing/libflex/FLEX"
if [ ! -d "$FLEX_DIR/Classes" ]; then
  rm -rf "$FLEX_DIR"
  mkdir -p "$(dirname "$FLEX_DIR")"
  git clone --depth=1 https://github.com/FLEXTool/FLEX.git "$FLEX_DIR"
fi

echo "[WAGram] Building..."
make package FINALPACKAGE=1 "$@"
echo "[WAGram] Done."
