#!/usr/bin/env python3
from pathlib import Path
import re, sys
root=Path(sys.argv[1] if len(sys.argv)>1 else '.').resolve()
checks=[
 ('src/Menu/WAGRMenuTheme.m','UIGlassEffect'),
 ('src/Menu/WAGRMenuTheme.m','clearGlassButtonConfiguration'),
 ('src/Menu/WAGRSurfaceListVC.m','ABProperties live'),
 ('src/Menu/WAGRSurfaceBrowserVC.m','WAGRRuntimeClassPrefix'),
 ('src/Menu/WAGRABPropsRootVC.m','WAGRWAABObservedKeys'),
 ('src/Hooks/WAGRGateHooks.xm','WAGRWAABObservedKeys'),
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
]:
    p=root/rel
    if p.exists() and bad in p.read_text(errors='ignore'): errors.append(f'{rel} contains old token {bad}')

# Link sanity: exported C symbols must have exactly one owner. Ignore pure declarations ending with ';'.
extern_def = re.compile(r'extern\s+"C"\s+[A-Za-z_][\w\s\*<>:]*?\s+(WAGR\w+)\s*\([^;{]*\)\s*\{')
owners={}
for p in sorted((root/'src').rglob('*')):
    if p.suffix not in {'.m','.mm','.x','.xm','.h'}: continue
    txt=p.read_text(errors='ignore')
    for m in extern_def.finditer(txt):
        owners.setdefault(m.group(1), []).append(str(p.relative_to(root)))
for sym, files in sorted(owners.items()):
    uniq=sorted(set(files))
    if len(uniq)>1:
        errors.append(f'duplicate exported symbol {sym}: {uniq}')

if (root/'src/Hooks/WAGRAuraNavigationHooks.xm').exists() and (root/'src/Hooks/WAAuraHooks.xm').exists():
    errors.append('WAGRAuraNavigationHooks.xm must not coexist with WAAuraHooks.xm')

if errors:
    for e in errors: print('ERRO:', e)
    sys.exit(1)
print('WATweaks LiquidGlass/live-runtime validation OK')
