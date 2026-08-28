#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
errors = []

def read(rel):
    p = root / rel
    if not p.exists():
        errors.append(f"missing {rel}")
        return ""
    return p.read_text(errors="ignore")

# Core file presence.
for rel in [
    "Makefile",
    "build.sh",
    "control",
    "WATweaks.plist",
    "src/Tweak.x",
    "src/Menu/WAGRSurfaceListVC.m",
    "src/Menu/WAGRSurfaceBrowserVC.m",
    "src/Menu/WAGRMainSettingsVC.m",
    "src/Runtime/WAGRSurface.m",
    "src/Runtime/WAGRABPropsABTForceFull.m",
    "src/Runtime/WAGRABPropsABTLiveService.m",
    "src/Runtime/WAGRABPropsABTLab.m",
    "src/Runtime/WAGRABPropsABTTransactionGate.m",
    "src/Menu/WAGRABPropsABTLabVC.m",
    "src/Runtime/WAGRABPropsReleaseNativeLinkage.m",
    "src/Runtime/WAGRMobileConfigNativeEngine.m",
]:
    if not (root / rel).exists():
        errors.append(f"missing {rel}")

# Local imports must exist.
for p in list((root / "src").rglob("*.m")) + list((root / "src").rglob("*.x")) + list((root / "src").rglob("*.xm")) + list((root / "src").rglob("*.h")):
    s = p.read_text(errors="ignore")
    for inc in re.findall(r'#import\s+"([^"]+)"', s):
        candidates = [p.parent / inc, root / "src" / inc, root / inc]
        if not any(c.exists() for c in candidates):
            errors.append(f"{p.relative_to(root)}: missing import {inc}")

# Longpress must remain in Tweak.x.
tweak = read("src/Tweak.x")
for token in ["UILongPressGestureRecognizer", "WAGRLP", "attachLP", "isTrigger", "WAGRPresent"]:
    if token not in tweak:
        errors.append(f"Tweak.x missing longpress token {token}")


# Basic Objective-C syntax tripwires that previously escaped static validation.
if 'new]})' in tweak or 'new]});' in tweak:
    errors.append('Tweak.x has dispatch_once block assignment without semicolon inside block')
if ']action:' in tweak:
    errors.append('Tweak.x has Objective-C message keyword glued to previous argument: ]action:')

# Main settings must expose the current semantic/native entry points. The old
# Ryuk feature-bundle assertions referenced files removed by this architecture.
menu = read("src/Menu/WAGRMainSettingsVC.m")
models = read("src/Runtime/WAGRSurface.m")
for token in ["AB Props", "MobileConfig / arquivos", "Runtime em tempo real"]:
    if token not in menu:
        errors.append(f"WAGRMainSettingsVC.m missing {token}")

# Surface browser must not show segmented SYS/OFF/ON.
browser = read("src/Menu/WAGRSurfaceBrowserVC.m")
if "UISegmentedControl" in browser or '@"SYS"' in browser or '@"OFF"' in browser or '@"ON"' in browser:
    errors.append("WAGRSurfaceBrowserVC.m still has segmented SYS/OFF/ON UI")
if "UISwitch" not in browser:
    errors.append("WAGRSurfaceBrowserVC.m missing UISwitch")
if "@property @property" in browser:
    errors.append("WAGRSurfaceBrowserVC.m can render duplicated @property")

# Scanner must not prefix displayName with @property.
scanner = read("src/Runtime/WAGRSurface.m")
if 'displayName = [@"@property "' in scanner:
    errors.append("scanner still adds @property prefix to displayName")
for token in ["selectorTokens", "scanProperties"]:
    if token not in scanner and token not in read("src/Runtime/WAGRSurface.h"):
        errors.append(f"runtime model missing {token}")

# ObjC++ function pointers must use explicit casts for NSValue bridging.
for p in list((root / "src").rglob("*.xm")) + list((root / "src").rglob("*.mm")):
    s = p.read_text(errors="ignore")
    for i, line in enumerate(s.splitlines(), 1):
        if "valueWithPointer:" in line and "reinterpret_cast<const void *>" not in line and "(const void *)" not in line:
            errors.append(f"{p.relative_to(root)}:{i}: valueWithPointer missing explicit function-pointer cast")
        if re.search(r'\([A-Za-z_][A-Za-z0-9_]*IMP\)\s*\[[^\]]+\s+pointerValue\]', line):
            errors.append(f"{p.relative_to(root)}:{i}: pointerValue uses C-style function pointer cast")

if errors:
    for e in errors:
        print("ERRO:", e, file=sys.stderr)
    sys.exit(1)

print("OK: WATweaks source/import/runtime validation passed")
