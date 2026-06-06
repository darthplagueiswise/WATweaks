#!/usr/bin/env python3
from pathlib import Path
import re, sys
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
errors = []
obsolete = [
    'src/Hooks/WAGRAuraNavigationHooks.xm',
    'src/Runtime/WAGRRuntimeCompat.m',
    'src/Runtime/WAGRRuntimeCompat.h',
    'src/Menu/WAGRResetRuntimeOverridesFix.xm',
]
for rel in obsolete:
    if (root / rel).exists():
        errors.append(f'obsolete duplicate-owner file still present: {rel}')

srcs = []
for p in root.joinpath('src').rglob('*'):
    if p.suffix.lower() in {'.m', '.x', '.xm', '.mm'}:
        # These must not compile even if accidentally present.
        if str(p.relative_to(root)).replace('\\','/') in obsolete:
            continue
        srcs.append(p)

def strip_comments(s: str) -> str:
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    s = re.sub(r'//.*', '', s)
    return s

# extern "C" function definitions and forward declarations in implementation files.
defs = {}
decls = {}
def_re = re.compile(r'extern\s+"C"\s+[^;{}#]*?\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{', re.S)
decl_re = re.compile(r'extern\s+"C"\s+[^;{}#]*?\b([A-Za-z_]\w*)\s*\([^{}]*?\)\s*;', re.S)
for p in srcs:
    text = strip_comments(p.read_text(errors='ignore'))
    rel = str(p.relative_to(root))
    for m in def_re.finditer(text):
        defs.setdefault(m.group(1), []).append(rel)
    for m in decl_re.finditer(text):
        decls.setdefault(m.group(1), []).append(rel)

for name, files in sorted(defs.items()):
    uniq = sorted(set(files))
    if len(uniq) > 1:
        errors.append(f'duplicate extern C definition {name}: ' + ', '.join(uniq))

# Internal WAGR/WA exported C declarations in .m/.xm should resolve inside the tweak.
# Ignore plain system/third-party-looking names by requiring WAGR/WA prefix.
for name, files in sorted(decls.items()):
    if not (name.startswith('WAGR') or name.startswith('WA')):
        continue
    if name not in defs:
        errors.append(f'unresolved extern C declaration {name}: ' + ', '.join(sorted(set(files))))

if errors:
    for e in errors:
        print('ERRO:', e, file=sys.stderr)
    sys.exit(1)
print('WATweaks link sanity validation OK')
