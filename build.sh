#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "[WATweaks] Building rootless package..."
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless "$@"
echo "[WATweaks] Done."
