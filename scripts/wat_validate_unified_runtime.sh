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
[ ! -f src/Hooks/WAGRAuraNavigationHooks.xm ] || err "obsolete duplicate-owner file still present: src/Hooks/WAGRAuraNavigationHooks.xm"
[ ! -f src/Runtime/WAGRRuntimeCompat.m ] || err "obsolete duplicate-owner file still present: src/Runtime/WAGRRuntimeCompat.m"
[ ! -f src/Menu/WAGRResetRuntimeOverridesFix.xm ] || err "obsolete duplicate-owner file still present: src/Menu/WAGRResetRuntimeOverridesFix.xm"

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
need_grep src/WAGramPrefix.h 'kWAGRAuraSimulation'
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


python3 scripts/wat_validate_link_sanity.py .

python3 - "." <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
used = {}
texts = []
for p in root.joinpath('src').rglob('*'):
    if p.suffix.lower() in {'.h','.m','.x','.xm','.mm'}:
        data = p.read_text(errors='ignore')
        texts.append(data)
        for m in re.finditer(r'\bkWAGR[A-Za-z0-9_]+\b', data):
            used.setdefault(m.group(), set()).add(str(p.relative_to(root)))
blob = '\n'.join(texts)
defs = set(re.findall(r'#\s*define\s+(kWAGR[A-Za-z0-9_]+)\b', blob))
defs |= set(re.findall(r'(kWAGR[A-Za-z0-9_]+)\s*=', blob))
missing = {k: sorted(v) for k, v in used.items() if k not in defs}
if missing:
    for k, paths in sorted(missing.items()):
        print('ERRO: undefined pref macro %s used in %s' % (k, ', '.join(paths)), file=sys.stderr)
    sys.exit(1)
print('WATweaks pref macro validation OK')
PY

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "WATweaks unified runtime/menu validation OK"
