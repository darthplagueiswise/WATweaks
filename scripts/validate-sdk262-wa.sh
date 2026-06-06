#!/bin/sh
set -eu
cd "${1:-.}"
fail=0
need_file(){ [ -f "$1" ] || { echo "missing: $1"; fail=1; }; }
need_grep(){ grep -q "$2" "$1" || { echo "missing pattern in $1: $2"; fail=1; }; }
need_absent(){ if grep -q "$2" "$1"; then echo "forbidden pattern in $1: $2"; fail=1; fi; }

need_file Makefile
need_grep Makefile 'iphone:clang:26.2:15.0'
need_grep Makefile '_USE_MODULES = 0'
need_file src/Hooks/WAGRGateHooks.xm
need_grep src/Hooks/WAGRGateHooks.xm 'WAGRWAABObservedKeys'
need_grep src/Hooks/WAGRGateHooks.xm 'integerForKey:defaultValue:'
need_grep src/Hooks/WAGRGateHooks.xm 'doubleForKey:defaultValue:'
need_file src/Menu/WAGRMenuTheme.m
need_grep src/Menu/WAGRMenuTheme.m 'UIGlassEffect'
need_grep src/Menu/WAGRMenuTheme.m 'clearGlassButtonConfiguration'
need_grep src/Menu/WAGRMenuTheme.m 'setPreferredContainerBackgroundStyle:'
need_grep src/Menu/WAGRMenuTheme.m 'WAGRStyleSearchBarForGlass'
need_absent src/Menu/WAGRMenuTheme.m 'UIBlurEffect'
need_absent src/Menu/WAGRMenuTheme.m 'SystemUltraThinMaterial'
need_absent src/Menu/WAGRMenuTheme.m 'SystemChromeMaterial'
need_file src/Menu/WAGRSurfaceListVC.m
need_grep src/Menu/WAGRSurfaceListVC.m 'ABProperties live'
need_grep src/Menu/WAGRSurfaceListVC.m 'Developer / Dogfood / Internal'
need_absent src/Menu/WAGRSurfaceListVC.m 'WAGRRootSectionFeatureSurfaces'
need_absent src/Menu/WAGRSurfaceListVC.m 'Features confirmadas no binário'
need_file src/Menu/WAGRSurfaceBrowserVC.m
need_grep src/Menu/WAGRSurfaceBrowserVC.m 'WAGRRuntimeClassPrefix'
need_absent src/Menu/WAGRSurfaceBrowserVC.m 'WAGRRuntimeSubcategoryForName'
need_absent src/Menu/WAGRSurfaceBrowserVC.m 'WAGRRuntimeSectionForSelector'
need_file src/Menu/WAGRABPropsRootVC.m
need_grep src/Menu/WAGRABPropsRootVC.m 'WAGRWAABObservedKeys'
need_grep src/Menu/WAGRABPropsRootVC.m 'sortedArrayUsingSelector'
need_absent src/Menu/WAGRABPropsRootVC.m 'WAGRGateRegistry providerWithID'
need_file resources/waab_feature_flags.json.gz
need_file resources/runtime/wa_runtime_exec.json
need_file resources/runtime/wa_runtime_sharedmodules.json
if [ "$fail" -ne 0 ]; then exit 1; fi
echo "WATweaks SDK26.2 liquidglass/live-runtime validation OK"
