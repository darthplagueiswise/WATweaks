#!/bin/sh
set -eu
ROOT="${1:-.}"
PATCH_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
# Remove duplicate/obsolete owners left by older broken patches.
rm -f src/Hooks/WAGRAuraNavigationHooks.xm
rm -f src/Hooks/WAGRObjCHookRouter.xm
rm -f src/Menu/WAGRResetRuntimeOverridesFix.xm
# Copy patch files.
for d in src scripts resources reports; do
  if [ -d "$PATCH_DIR/$d" ]; then
    mkdir -p "$d"
    cp -a "$PATCH_DIR/$d/." "$d/"
  fi
done
[ -f "$PATCH_DIR/Makefile" ] && cp -f "$PATCH_DIR/Makefile" Makefile
[ -f "$PATCH_DIR/build.sh" ] && cp -f "$PATCH_DIR/build.sh" build.sh
chmod +x scripts/*.sh 2>/dev/null || true
chmod +x build.sh 2>/dev/null || true
echo "applied liquidglass live runtime v14 to $ROOT"
