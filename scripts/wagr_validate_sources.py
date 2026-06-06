#!/usr/bin/env python3
from pathlib import Path
import re, sys, collections
root = Path(__file__).resolve().parents[1]
errors=[]

def read(rel):
    p=root/rel
    if not p.exists():
        errors.append(f"missing {rel}"); return ""
    return p.read_text(errors='ignore')

required = [
    'Makefile','build.sh','control','WATweaks.plist','src/Tweak.x',
    'src/Menu/WAGRMenuTheme.m','src/Menu/WAGRSurfaceListVC.m','src/Menu/WAGRSurfaceBrowserVC.m','src/Menu/WAGRABPropsRootVC.m',
    'src/Runtime/WAGRSurface.m','src/Runtime/WAGRGateStore.m','src/Runtime/WAGRRuntimeCompat.m','src/Hooks/WAGRGateHooks.xm','src/Hooks/WAAuraHooks.xm'
]
for rel in required:
    if not (root/rel).exists(): errors.append(f"missing {rel}")

# Local imports must resolve.
for p in list((root/'src').rglob('*.m')) + list((root/'src').rglob('*.x')) + list((root/'src').rglob('*.xm')) + list((root/'src').rglob('*.h')):
    s=p.read_text(errors='ignore')
    for inc in re.findall(r'#import\s+"([^"]+)"', s):
        candidates=[p.parent/inc, root/'src'/inc, root/inc]
        if not any(c.exists() for c in candidates): errors.append(f"{p.relative_to(root)}: missing import {inc}")

# LiquidGlass/root/menu assertions.
menu=read('src/Menu/WAGRSurfaceListVC.m')
for token in ['ABProperties live','Runtime — WhatsApp','Runtime — SharedModules','Developer / Dogfood / Internal']:
    if token not in menu: errors.append(f"WAGRSurfaceListVC.m missing {token}")
for bad in ['WAGRRootSectionFeatureSurfaces','WAGRFeatureRow','Debug menu catalog','Features confirmadas no binário']:
    if bad in menu: errors.append(f"WAGRSurfaceListVC.m still contains old menu token {bad}")

theme=read('src/Menu/WAGRMenuTheme.m')
for token in ['UIGlassEffect','clearGlassButtonConfiguration','WAGRRealLiquidGlassEffect','WAGRApplyGlassBackdropToViewController','WAGRStyleSearchBarForGlass']:
    if token not in theme: errors.append(f"WAGRMenuTheme.m missing LiquidGlass token {token}")
for bad in ['UIBlurEffectStyleSystem','SystemUltraThinMaterial','SystemChromeMaterial','UIBlurEffect']:
    if bad in theme: errors.append(f"WAGRMenuTheme.m contains fake blur/material token {bad}")

browser=read('src/Menu/WAGRSurfaceBrowserVC.m')
if 'WAGRRuntimeClassPrefix' not in browser: errors.append('runtime browser missing class-prefix grouping')
for bad in ['WAGRRuntimeSubcategoryForName','WAGRRuntimeSectionForSelector','Positive · Enabled','Negative · Disabled','Experiment / Sync']:
    if bad in browser: errors.append(f"runtime browser still has semantic categorization token {bad}")
if 'UISwitch' not in browser: errors.append('runtime browser missing UISwitch')

ab=read('src/Menu/WAGRABPropsRootVC.m')
for token in ['WAGRWAABObservedKeys','ABProperties é lido em runtime','sortedArrayUsingSelector']:
    if token not in ab: errors.append(f"ABPropsRoot missing {token}")
for bad in ['providerWithID','WAGRGateCategoryVC','Categorias principais','LiquidGlass" detail']:
    if bad in ab: errors.append(f"ABPropsRoot still has old provider/category token {bad}")

surf=read('src/Runtime/WAGRSurface.m')
for token in ['Runtime - WhatsApp executable','Runtime - SharedModules.framework','No semantic token filter']:
    if token not in surf: errors.append(f"WAGRSurface.m missing {token}")
for bad in ['kWAGRSurfaceWAAB','kWAGRSurfaceContext','kWAGRSurfaceGateKeep','kWAGRSurfaceAura','WAGROverrideKey']:
    if bad in surf: errors.append(f"WAGRSurface.m still contains old token {bad}")

# One prefix policy: new direct constants should be watweak_*.
prefix=read('src/WAPrefix.h')
for line in prefix.splitlines():
    if line.startswith('#define WA_PREF_') and '"watweak_' not in line:
        errors.append(f"WAPrefix direct preference is not watweak_: {line}")

# Duplicate owner files must not exist.
for rel in ['src/Hooks/WAGRAuraNavigationHooks.xm','src/Hooks/WAGRObjCHookRouter.xm','src/Menu/WAGRResetRuntimeOverridesFix.xm']:
    if (root/rel).exists(): errors.append(f"forbidden stale duplicate owner exists: {rel}")

# Duplicate exported C symbols guard.
defs=collections.defaultdict(list)
for p in list((root/'src').rglob('*.m')) + list((root/'src').rglob('*.xm')) + list((root/'src').rglob('*.mm')) + list((root/'src').rglob('*.x')):
    s=p.read_text(errors='ignore')
    for m in re.finditer(r'extern\s+"C"\s+(?:[A-Za-z_][\w:<>,\s\*]+)\s+((?:WAGR|WA)[A-Za-z0-9_]+)\s*\([^;{}]*\)\s*\{', s, re.M):
        defs[m.group(1)].append(str(p.relative_to(root)))
for name, files in sorted(defs.items()):
    if len(files)>1:
        errors.append(f"duplicate exported symbol {name}: {files}")

# Old pointerValue C-style function pointer cast guard.
for p in list((root/'src').rglob('*.xm')) + list((root/'src').rglob('*.mm')):
    for i,line in enumerate(p.read_text(errors='ignore').splitlines(),1):
        if 'pointerValue]' in line and re.search(r'=\s*\([A-Za-z_][A-Za-z0-9_]*IMP\)\s*\[.*pointerValue\]', line):
            errors.append(f"{p.relative_to(root)}:{i}: pointerValue uses C-style function pointer cast")

# Check pref key macros used in WAGRPref()/NSUserDefaults forKey: have a define.
# Do not flag local static constants like kWAGRMaxLogLines.
all_text = '\n'.join(p.read_text(errors='ignore') for p in list((root/'src').rglob('*.h')) + list((root/'src').rglob('*.m')) + list((root/'src').rglob('*.xm')) + list((root/'src').rglob('*.x')))
defined=set(re.findall(r'#define\s+(kWAGR[A-Za-z0-9_]+)\b', all_text))
# String constants such as kWAGRStorageWipedMarkerV2 are valid managed keys too;
# they must not be forced into #define form because that would corrupt extern
# declarations like: extern NSString * const kWAGRStorageWipedMarkerV2;
const_declared=set(re.findall(r'(?:extern\s+)?NSString\s*\*\s*const\s+(kWAGR[A-Za-z0-9_]+)\b', all_text))
known=defined | const_declared
used=set(re.findall(r'WAGRPref\s*\(\s*(kWAGR[A-Za-z0-9_]+)\s*\)', all_text))
used.update(re.findall(r'forKey\s*:\s*(kWAGR[A-Za-z0-9_]+)', all_text))
used.update(re.findall(r'boolForKey\s*:\s*(kWAGR[A-Za-z0-9_]+)', all_text))
used.update(re.findall(r'setBool\s*:[^;\n]+forKey\s*:\s*(kWAGR[A-Za-z0-9_]+)', all_text))
used.update(re.findall(r'removeObjectForKey\s*:\s*(kWAGR[A-Za-z0-9_]+)', all_text))
for m in sorted(u for u in used if u not in known):
    errors.append(f"missing pref key definition: {m}")

if errors:
    for e in errors: print('ERRO:', e)
    sys.exit(1)
print('OK: WATweaks liquidglass/live runtime source validation passed')
