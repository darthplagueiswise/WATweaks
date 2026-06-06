#!/bin/sh
set -eu
ROOT="${1:-.}"
cd "$ROOT"
fail=0
err(){ echo "ERRO: $*" >&2; fail=1; }
need_file(){ [ -f "$1" ] || err "missing $1"; }
need_grep(){ grep -q "$2" "$1" || err "$1 missing pattern: $2"; }
need_absent(){ if grep -q "$2" "$1"; then err "$1 forbidden pattern: $2"; fi; }

need_file Makefile
need_file build.sh
need_file .github/workflows/build-watweaks.yml
need_file src/Hooks/WAGRSettingsRowsNativeHooks.xm
need_file src/Tweak.x
need_file src/WAGramPrefix.h
need_file src/Menu/WAGRSurfaceListVC.m
need_file src/Menu/WAGRSettingsBackup.m
need_file src/Hooks/WAGRObjCHookRouter.xm

need_grep Makefile 'iphone:clang:26.2:15.0'
need_grep Makefile '_USE_MODULES = 0'
need_grep build.sh '\[WATweaks\] Building'
need_absent build.sh 'WAGram'
need_grep .github/workflows/build-watweaks.yml 'iPhoneOS26.2.sdk'
need_grep .github/workflows/build-watweaks.yml 'WATweaks${BUILD_VERSION}.deb'

need_grep src/Hooks/WAGRSettingsRowsNativeHooks.xm 'WAGRSettingsRowsNativeEnsureHooksInstalled'
need_grep src/Hooks/WAGRSettingsRowsNativeHooks.xm 'WAGRSettingsRowsNativeInjectIfPossible'
need_grep src/Hooks/WAGRSettingsRowsNativeHooks.xm 'WAGRSettingsRowsNativeDiagnosticText'
need_absent src/Hooks/WAGRSettingsRowsNativeHooks.xm 'WATweaksSettingsButton'
need_absent src/Hooks/WAGRSettingsRowsNativeHooks.xm 'openWATweaks'
need_absent src/Hooks/WAGRSettingsRowsNativeHooks.xm 'initWithImage:image style:UIBarButtonItemStylePlain'
need_absent src/Hooks/WAGRSettingsRowsNativeHooks.xm 'WAGRPresentWATweaksMenuFromSettings'

need_absent src/Tweak.x 'startupHooksEnabled'
need_absent src/Tweak.x 'containsString:@"watweaks"'
need_grep src/Tweak.x 'WAGRReinstallPersistedHooks();'

need_grep src/WAGramPrefix.h 'WAGRIsRuntimeOverridePreferenceKey'
need_grep src/WAGramPrefix.h 'WAGRClearRuntimeOverridePreferences'
need_grep src/WAGramPrefix.h 'WAGRClearAllManagedPreferences'
need_grep src/WAGramPrefix.h 'WAGRIsManagedPreferenceKey'
need_grep src/WAGramPrefix.h 'kWAGRGateEligibility'
need_grep src/WAGramPrefix.h 'kWAGRGateUsername'
need_grep src/WAGramPrefix.h 'kWAGRGatePremiumBroadcast'
need_file src/Hooks/WAGRGlobalGateStub.xm
need_grep src/Hooks/WAGRGlobalGateStub.xm 'kWAGRGateEligibility'
need_grep src/Hooks/WAGRGlobalGateStub.xm 'kWAGRGateUsername'
need_grep src/Hooks/WAGRGlobalGateStub.xm 'kWAGRGatePremiumBroadcast'

need_grep src/Menu/WAGRSurfaceListVC.m 'WAGRClearRuntimeOverridePreferences'
need_grep src/Menu/WAGRSurfaceListVC.m 'WAGRClearAllManagedPreferences'
need_absent src/Menu/WAGRSurfaceListVC.m 'WATweaks que aparece abaixo do Developer'
need_grep src/Menu/WAGRSettingsBackup.m 'WAGRIsManagedPreferenceKey'
need_grep src/Menu/WAGRSettingsBackup.m 'WAGRClearAllManagedPreferences'

# Existing project validation must still pass.
python3 scripts/wagr_validate_sources.py >/tmp/wat_validate_wagr.out
cat /tmp/wat_validate_wagr.out

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "WATweaks unified runtime/menu validation OK"
