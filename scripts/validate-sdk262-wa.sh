#!/bin/sh
set -eu
cd "${1:-.}"
fail=0
need_file(){ [ -f "$1" ] || { echo "missing: $1"; fail=1; }; }
need_grep(){ grep -q "$2" "$1" || { echo "missing pattern in $1: $2"; fail=1; }; }
need_absent(){ if [ -f "$1" ] && grep -q "$2" "$1"; then echo "forbidden pattern in $1: $2"; fail=1; fi; }
need_file Makefile
need_grep Makefile 'iphone:clang:26.2:15.0'
need_grep Makefile '_USE_MODULES = 0'
if [ -f src/Hooks/WAGRGateHooks.xm ]; then
  need_grep src/Hooks/WAGRGateHooks.xm 'integerForKey:defaultValue:'
  need_grep src/Hooks/WAGRGateHooks.xm 'doubleForKey:defaultValue:'
fi
need_grep src/WAGramPrefix.h 'kWAGRGateEligibility'
need_grep src/WAGramPrefix.h 'kWAGRGateUsername'
need_grep src/WAGramPrefix.h 'kWAGRGatePremiumBroadcast'
need_grep src/WAGramPrefix.h 'kWAGRAuraSimulation'
need_file src/Hooks/WAAuraHooks.xm
need_grep src/Hooks/WAAuraHooks.xm 'aura_subscription_simulation_enabled'
need_grep src/Hooks/WAAuraHooks.xm 'WAAuraGating'
need_file src/Hooks/WAGRLiquidGlassHooks.xm
need_grep src/Hooks/WAGRLiquidGlassHooks.xm 'isUnifyHoverActionsEnabled'
need_file src/Runtime/WAGRSurface.m
need_grep src/Runtime/WAGRSurface.m 'Runtime - WhatsApp executable'
need_grep src/Runtime/WAGRSurface.m 'Runtime - SharedModules.framework'
need_grep src/Runtime/WAGRSurface.m 'No semantic token filter'
need_file src/Menu/WAGRSurfaceListVC.m
need_grep src/Menu/WAGRSurfaceListVC.m 'WAGRRootSectionFeatureSurfaces'
need_grep src/Menu/WAGRSurfaceListVC.m 'Features confirmadas no binário'
need_absent src/Menu/WAGRSurfaceListVC.m 'WAGRFeatureGateRows'
need_absent src/Menu/WAGRSurfaceListVC.m 'UISwitch'
if [ -f src/Menu/WAGRMenuTheme.m ]; then
  need_absent src/Menu/WAGRMenuTheme.m 'UIBlurEffect'
  need_absent src/Menu/WAGRMenuTheme.m 'SystemUltraThinMaterial'
  need_absent src/Menu/WAGRMenuTheme.m 'SystemChromeMaterial'
  need_absent src/Menu/WAGRMenuTheme.m 'backgroundEffect'
fi
[ -f resources/waab_feature_flags.json.gz ] || echo "warning: resources/waab_feature_flags.json.gz absent in this tree"
[ -f resources/runtime/wa_runtime_exec.json ] || echo "warning: resources/runtime/wa_runtime_exec.json absent in this tree"
[ -f resources/runtime/wa_runtime_sharedmodules.json ] || echo "warning: resources/runtime/wa_runtime_sharedmodules.json absent in this tree"

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
echo "WATweaks SDK26.2 grounded UI/runtime validation OK"
