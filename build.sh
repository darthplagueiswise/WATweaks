#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Ensure THEOS is exported when not set by the environment (CI sets this already).
if [ -z "${THEOS-}" ]; then
  THEOS="$HOME/theos"
  export THEOS
  echo "[WATweaks] THEOS not set; defaulting to $THEOS"
else
  echo "[WATweaks] THEOS=$THEOS"
fi

echo "[WATweaks] Building..."
make package FINALPACKAGE=1 "$@"
echo "[WATweaks] Done."
