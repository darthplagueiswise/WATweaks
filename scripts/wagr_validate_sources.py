#!/usr/bin/env python3
from pathlib import Path
import re, sys, collections
root = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
errors=[]
def err(m): errors.append('ERRO: '+m)
source_exts={'.h','.m','.mm','.x','.xm'}
files=[p for p in root.rglob('*') if p.is_file() and p.suffix in source_exts and '.theos' not in p.parts]
texts={}
for p in files:
    texts[p]=p.read_text(errors='ignore')
required=['Makefile','build.sh','src/Tweak.x','src/Menu/WAGRMenuTheme.m','src/Menu/WAGRSurfaceListVC.m','src/Menu/WAGRABPropsRootVC.m','src/Menu/WAGRSurfaceBrowserVC.m','src/Hooks/WAGRGateHooks.xm','src/Hooks/WAGRAuraCompatExports.xm','src/Runtime/WAGRSurface.m']
for r in required:
    if not (root/r).exists(): err(f'missing {r}')
all_text='\n'.join(texts.values())
# local imports exist
for p,s in texts.items():
    for inc in re.findall(r'#import\s+"([^"]+)"', s):
        candidates=[p.parent/inc, root/'src'/inc, root/inc]
        if not any(c.exists() for c in candidates): err(f'{p.relative_to(root)}: missing import {inc}')
# duplicate exported function definitions, not declarations
pat=re.compile(r'extern\s+"C"\s+(?:[A-Za-z_][\w:<>,\s\*]+?)\s+((?:WAGR|WA)[A-Za-z0-9_]+)\s*\([^;{}]*\)\s*\{', re.M)
d=collections.defaultdict(list)
for p,s in texts.items():
    for m in pat.finditer(s): d[m.group(1)].append(str(p.relative_to(root)))
for k,v in sorted(d.items()):
    if len(set(v))>1: err(f'duplicate exported symbol {k}: {sorted(set(v))}')
# no stale duplicate owner files
for rel in ['src/Hooks/WAGRAuraNavigationHooks.xm','src/Hooks/WAGRObjCHookRouter.xm','src/Menu/WAGRResetRuntimeOverridesFix.xm']:
    if (root/rel).exists(): err(f'forbidden stale duplicate owner exists: {rel}')
# function pointer bridge style
for p,s in texts.items():
    for i,line in enumerate(s.splitlines(),1):
        if 'valueWithPointer:' in line and 'reinterpret_cast<const void *>' not in line and '(const void *)' not in line and '(__bridge const void *)' not in line:
            err(f'{p.relative_to(root)}:{i}: valueWithPointer missing explicit cast')
        if re.search(r'\([A-Za-z_][A-Za-z0-9_]*IMP\)\s*\[[^\]]+\s+pointerValue\]', line):
            err(f'{p.relative_to(root)}:{i}: pointerValue uses C-style function pointer cast')
# kWAGR* definitions can be macro or NSString const
names=set(re.findall(r'\b(kWAGR[A-Za-z0-9_]+)\b', all_text))
defined=set(re.findall(r'^\s*#\s*define\s+(kWAGR[A-Za-z0-9_]+)\b', all_text, re.M))
defined |= set(re.findall(r'\b(?:extern\s+)?NSString\s*\*\s*const\s+(kWAGR[A-Za-z0-9_]+)\b', all_text))
for n in sorted(names):
    # ignore local static constants not prefs or exported keys
    if n in ['kWAGRGlassBackgroundTag','kWAGRMaxLogLines','kWAGRPrivateExpVisibleKickDone','kWAGRSettingsButtonTargetKey','kWAGRSettingsButtonInstalledKey','kWAGRNativeSettingsRefreshMarker','kWAGRDebugQuickAccessTargetKey','kWAGRDebugBackTargetKey','kWAGRDMExtraSectionRows']:
        continue
    if n not in defined: err(f'missing pref define/const: {n}')
if errors:
    print('\n'.join(errors)); sys.exit(1)
print('OK: WATweaks source/link sanity validation passed')
