#!/bin/sh
set -eu
cd "${1:-.}"
fail=0
need_file(){ [ -f "$1" ] || { echo "missing: $1"; fail=1; }; }
need_grep(){ grep -q "$2" "$1" || { echo "missing pattern in $1: $2"; fail=1; }; }
need_file Makefile
need_grep Makefile 'iphone:clang:26.2:15.0'
need_file src/Hooks/WAGRGateHooks.xm
need_grep src/Hooks/WAGRGateHooks.xm 'integerForKey:defaultValue:'
need_grep src/Hooks/WAGRGateHooks.xm 'doubleForKey:defaultValue:'
need_file src/Hooks/WAAuraHooks.xm
need_grep src/Hooks/WAAuraHooks.xm 'aura_subscription_simulation_enabled'
need_grep src/Hooks/WAAuraHooks.xm 'WAAuraGating'
need_file src/Hooks/WAGRLiquidGlassHooks.xm
need_grep src/Hooks/WAGRLiquidGlassHooks.xm 'isUnifyHoverActionsEnabled'
need_file src/Runtime/WAGRSurface.m
need_grep src/Runtime/WAGRSurface.m 'Runtime Browser — WhatsApp Exec'
need_grep src/Runtime/WAGRSurface.m 'Runtime Browser — SharedModules'
need_file resources/waab_feature_flags.json.gz
need_file resources/runtime/wa_runtime_exec.json
need_file resources/runtime/wa_runtime_sharedmodules.json

need_grep src/Menu/WAGRMenuTheme.m 'UIGlassEffect'
need_grep src/Menu/WAGRMenuTheme.m 'UIGlassContainerEffect'
if grep -q 'UIBlurEffect\|SystemUltraThinMaterial\|SystemChromeMaterial\|backgroundEffect' src/Menu/WAGRMenuTheme.m; then
  echo "legacy blur/material found in WAGRMenuTheme.m"
  fail=1
fi
if [ "$fail" -ne 0 ]; then exit 1; fi
echo "WATweaks SDK26.2 patch validation OK"
