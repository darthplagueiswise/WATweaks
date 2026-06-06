#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "[WATweaks] Building..."
make package FINALPACKAGE=1 "$@"
echo "[WATweaks] Done."
