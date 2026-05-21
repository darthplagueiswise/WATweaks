#!/usr/bin/env bash
# build.sh — build WATweaks tweak (normal device install)
set -euo pipefail

cd "$(dirname "$0")"

echo "[WATweaks] Building..."
make package FINALPACKAGE=1 "$@"
echo "[WATweaks] Done."
