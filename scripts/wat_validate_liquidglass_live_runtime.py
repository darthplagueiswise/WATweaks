#!/usr/bin/env python3
from pathlib import Path
import re, sys, collections
root=Path(sys.argv[1] if len(sys.argv)>1 else '.').resolve()
checks=[
 ('src/Menu/WAGRMenuTheme.m','UIGlassEffect'),
 ('src/Menu/WAGRMenuTheme.m','clearGlassButtonConfiguration'),
 ('src/Menu/WAGRSurfaceListVC.m','ABProperties live'),
 ('src/Menu/WAGRSurfaceBrowserVC.m','WAGRRuntimeClassPrefix'),
 ('src/Menu/WAGRABPropsRootVC.m','WAGRWAABObservedKeys'),
 ('src/Hooks/WAGRGateHooks.xm','WAGRWAABObservedKeys'),
 ('src/Runtime/WAGRSurface.m','Runtime - WhatsApp executable'),
 ('src/Runtime/WAGRSurface.m','Runtime - SharedModules.framework'),
 ('src/WAPrefix.h','watweak_ui_liquid_glass_enabled'),
]
errors=[]
for rel,tok in checks:
    p=root/rel
    if not p.exists(): errors.append(f'missing {rel}')
    elif tok not in p.read_text(errors='ignore'): errors.append(f'{rel} missing {tok}')
for rel,bad in [
 ('src/Menu/WAGRSurfaceBrowserVC.m','WAGRRuntimeSubcategoryForName'),
 ('src/Menu/WAGRSurfaceBrowserVC.m','Positive · Enabled'),
 ('src/Menu/WAGRABPropsRootVC.m','WAGRGateCategoryVC'),
 ('src/Menu/WAGRSurfaceListVC.m','Features confirmadas no binário'),
 ('src/Runtime/WAGRSurface.m','kWAGRSurfaceWAAB'),
 ('src/Runtime/WAGRSurface.m','WAGROverrideKey'),
]:
    p=root/rel
    if p.exists() and bad in p.read_text(errors='ignore'): errors.append(f'{rel} contains old token {bad}')
for rel in ['src/Hooks/WAGRAuraNavigationHooks.xm','src/Hooks/WAGRObjCHookRouter.xm']:
    if (root/rel).exists(): errors.append(f'forbidden stale duplicate owner exists: {rel}')
# duplicate exported C symbols
pat=re.compile(r'extern\s+"C"\s+(?:[A-Za-z_][\w:<>,\s\*]+)\s+((?:WAGR|WA)[A-Za-z0-9_]+)\s*\([^;{}]*\)\s*\{', re.M)
d=collections.defaultdict(list)
for p in list((root/'src').rglob('*.m'))+list((root/'src').rglob('*.xm'))+list((root/'src').rglob('*.mm'))+list((root/'src').rglob('*.x')):
    for m in pat.finditer(p.read_text(errors='ignore')): d[m.group(1)].append(str(p.relative_to(root)))
for k,v in sorted(d.items()):
    if len(v)>1: errors.append(f'duplicate exported symbol {k}: {v}')
if errors:
    for e in errors: print('ERRO:', e)
    sys.exit(1)
print('WATweaks LiquidGlass/live-runtime validation OK')
