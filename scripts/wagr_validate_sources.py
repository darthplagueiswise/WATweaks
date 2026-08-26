#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
errors = []


def read(rel: str) -> str:
    path = root / rel
    if not path.exists():
        errors.append(f"missing {rel}")
        return ""
    return path.read_text(errors="ignore")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda match: "\n" * match.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


# Canonical 8150 rebuild: validate what the branch actually compiles.  The old
# router-era ObjectGraphScanner/ObjCHookRouter/FeatureSubmenu units were removed
# intentionally and must not be required by this validator.
required = [
    "Makefile",
    "build.sh",
    "control",
    "WATweaks.plist",
    "src/Tweak.x",
    "src/Menu/WAGRMainSettingsVC.h",
    "src/Menu/WAGRMainSettingsVC.m",
    "src/Menu/WAGRABPropsRootVC.h",
    "src/Menu/WAGRABPropsRootVC.m",
    "src/Menu/WAGRABPropsBrowserVC.h",
    "src/Menu/WAGRABPropsBrowserVC.m",
    "src/Menu/WAGRABPropsFilteredBrowserVC.h",
    "src/Menu/WAGRABPropsFilteredBrowserVC.m",
    "src/Menu/WAGRValidatedNativeGatesVC.h",
    "src/Menu/WAGRValidatedNativeGatesVC.m",
    "src/Menu/WAGRSurfaceBrowserVC.h",
    "src/Menu/WAGRSurfaceBrowserVC.m",
    "src/Menu/WAGRRuntimeBrowserCrashGuard.m",
    "src/Menu/WAGRRuntimeObjectFullscreenEditor.m",
    "src/Runtime/WAGRSurface.h",
    "src/Runtime/WAGRSurface.m",
    "src/Runtime/WAGRFeatureState.h",
    "src/Runtime/WAGRFeatureState.m",
    "src/Runtime/WAGRRuntimeValueStore.h",
    "src/Runtime/WAGRRuntimeValueStore.m",
    "src/Runtime/WAGRABPropsRuntime.h",
    "src/Runtime/WAGRABPropsRuntime.m",
    "src/Runtime/WAGRABPropsNativeStore.h",
    "src/Runtime/WAGRABPropsNativeStore.m",
]
for rel in required:
    if not (root / rel).exists():
        errors.append(f"missing {rel}")

for obsolete in [
    "src/Menu/WAGRFeatureSubmenuVC.h",
    "src/Menu/WAGRFeatureSubmenuVC.m",
    "src/Runtime/WAGRObjectGraphScanner.m",
    "src/Hooks/WAGRObjCHookRouter.xm",
]:
    if (root / obsolete).exists():
        errors.append(f"obsolete router-era unit unexpectedly present: {obsolete}")

# Every local source import must resolve.  This catches real integration errors
# without assuming a superseded directory layout.
source_files = []
for suffix in ("*.m", "*.mm", "*.x", "*.xm", "*.h", "*.c", "*.cc", "*.cpp"):
    source_files.extend((root / "src").rglob(suffix))
for path in source_files:
    text = path.read_text(errors="ignore")
    for inc in re.findall(r'#import\s+"([^"]+)"', text):
        candidates = [path.parent / inc, root / "src" / inc, root / inc]
        if not any(candidate.exists() for candidate in candidates):
            errors.append(f"{path.relative_to(root)}: missing import {inc}")

# Long-press entry point is part of the base architecture and must survive the
# rebuild.
tweak = read("src/Tweak.x")
for token in ["UILongPressGestureRecognizer", "WAGRLP", "attachLP", "isTrigger", "WAGRPresent"]:
    if token not in tweak:
        errors.append(f"Tweak.x missing longpress token {token}")
if 'new]})' in tweak or 'new]});' in tweak:
    errors.append("Tweak.x has dispatch_once block assignment without semicolon inside block")
if ']action:' in tweak:
    errors.append("Tweak.x has Objective-C message keyword glued to previous argument: ]action:")

# Canonical root menu: curated Employee/Internal plus filtered ABProperties
# views for Aura/Liquid Glass, then native ABProps and generic live runtime.
menu = read("src/Menu/WAGRMainSettingsVC.m")
for token in [
    "Employee / Internal / Dogfood",
    "Aura",
    "Liquid Glass",
    "Debug menu nativo",
    "AB Props",
    "WAGRABPropsFilteredBrowserVC",
    'query:@"aura_"',
    'query:@"ios_liquid_glass_"',
    "WAGRValidatedNativeGatesVC",
    "WAGRSurfaceBrowserVC",
]:
    if token not in menu:
        errors.append(f"WAGRMainSettingsVC.m missing canonical menu token {token}")
if "WAGRFeatureSubmenuVC" in strip_comments(menu):
    errors.append("WAGRMainSettingsVC.m still references obsolete FeatureSubmenu router")

# Live runtime model must be image-backed and ABI/type filtered; it must not
# require opening a separate browser to populate hard-coded feature bundles.
surface_h = read("src/Runtime/WAGRSurface.h")
surface_m = read("src/Runtime/WAGRSurface.m")
for token in [
    "runtimeImageSurfaces",
    "runtimeFamilySurfaces",
    "runtimeImagePath",
    "runtimeFamilyKey",
    "WAGRRuntimeValueTypeIsSupported",
    "WAGRLiveMethodIsSupported",
    "objc_copyClassList",
]:
    if token not in surface_h + surface_m:
        errors.append(f"live runtime model missing {token}")
if 'displayName = [@"@property "' in strip_comments(surface_m):
    errors.append("runtime scanner still adds @property prefix to displayName")

# Runtime browser uses direct typed controls rather than the obsolete SYS/OFF/ON
# segmented policy.
browser = read("src/Menu/WAGRSurfaceBrowserVC.m")
browser_code = strip_comments(browser)
if "UISegmentedControl" in browser_code or '@"SYS"' in browser_code:
    errors.append("WAGRSurfaceBrowserVC.m still has segmented SYS/OFF/ON UI")
if "UISwitch" not in browser_code:
    errors.append("WAGRSurfaceBrowserVC.m missing UISwitch typed boolean UI")
if "@property @property" in browser_code:
    errors.append("WAGRSurfaceBrowserVC.m can render duplicated @property")

# The crash guard must be the conservative receiver resolver: exact live objects,
# validated singleton factories and UIKit ownership only; never arbitrary ivar
# graph traversal or fabricated instances. Ignore explanatory comments when
# checking forbidden runtime calls.
crash_guard = read("src/Menu/WAGRRuntimeBrowserCrashGuard.m")
crash_guard_code = strip_comments(crash_guard)
for token in ["WAGRSafeReceiverForEntry", "WAGRSafeExactReceiver", "WAGRSafeSingletonReceiver"]:
    if token not in crash_guard_code:
        errors.append(f"runtime crash guard missing {token}")
for forbidden in ["object_getIvar", "class_createInstance", "[cls alloc]"]:
    if forbidden in crash_guard_code:
        errors.append(f"runtime crash guard contains unsafe receiver operation {forbidden}")

# Curated feature state must resolve through the same RuntimeValueStore used by
# the ABProperties Browser, with the native gabp snapshot only as a read source.
feature_state = read("src/Runtime/WAGRFeatureState.m")
for token in [
    "WAGRRuntimeValueAllOverrideSpecs",
    "WAGRRuntimeValueSetOverride",
    "WAGRRuntimeValueClearOverride",
    "WAGRRuntimeValueInstallHook",
    "WAGRABPropsReadNativeSnapshot",
    "WAGRABPropsNativeExportDocument",
]:
    if token not in feature_state:
        errors.append(f"WAGRFeatureState.m missing shared-state token {token}")

# wamo_abprops_list is an object getter whose NSString contains a typed JSON
# schema.  The full-screen editor must preserve the outer ABI and validate inner
# values rather than converting the getter to an integer/object of another kind.
editor = read("src/Menu/WAGRRuntimeObjectFullscreenEditor.m")
for token in ["wamo_abprops_list", "typedABPropsSchema", "WAGRFullValidateABPropsSchema", "WAGRRuntimeValueSetOverride"]:
    if token not in editor:
        errors.append(f"WAGRRuntimeObjectFullscreenEditor.m missing {token}")

# ObjC++ function-pointer bridging: only IMP/function-pointer expressions require
# an explicit cast to const void*.  A normal data pointer (for example a heap
# descriptor struct) is already convertible to void* and must not be rejected.
functionish = re.compile(r"\b(?:IMP|imp|orig|original|replacement|hook)\b", re.I)
for path in list((root / "src").rglob("*.xm")) + list((root / "src").rglob("*.mm")):
    text = path.read_text(errors="ignore")
    for line_no, line in enumerate(text.splitlines(), 1):
        if "valueWithPointer:" in line:
            arg = line.split("valueWithPointer:", 1)[1]
            if functionish.search(arg) and "reinterpret_cast<const void *>" not in arg and "(const void *)" not in arg:
                errors.append(f"{path.relative_to(root)}:{line_no}: function pointer stored in NSValue without explicit void* cast")
        if re.search(r'\([A-Za-z_][A-Za-z0-9_]*IMP\)\s*\[[^\]]+\s+pointerValue\]', line):
            errors.append(f"{path.relative_to(root)}:{line_no}: pointerValue uses C-style function pointer cast")

if errors:
    for error in errors:
        print("ERRO:", error, file=sys.stderr)
    sys.exit(1)

print("OK: canonical 8150 rebuild source validation passed")
