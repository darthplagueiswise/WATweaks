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
    "src/Runtime/WAGRWAABFamilyCatalog.h",
    "src/Runtime/WAGRWAABFamilyCatalog.m",
    "resources/waab_family_catalog_26_40_10.json",
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
for token in ["Launcher dogfood", "WAGRLaunchNativeDeveloperMenu"]:
    if token not in menu:
        errors.append(f"WAGRMainSettingsVC.m missing verified dogfood surface {token}")

# WhatsApp 26.40.10 exposes dogfood through the verified URL/settings nudge.
# The removed debug-provider/private-experimentation controllers must not be
# fabricated as launch targets when they are absent from all supplied Mach-O.
launcher = read("src/Hooks/WAGRDebugMenuLauncher.xm")
if "https://fburl.com/df_iphone" not in launcher:
    errors.append("dogfood launcher missing verified https://fburl.com/df_iphone URL")
for obsolete in ("DebugMenuProvider", "WADebugViewController", "PrivateExperimentationDebugViewController"):
    if obsolete in launcher:
        errors.append(f"dogfood launcher still assumes absent native class {obsolete}")
for unsafe in ("wagr_bootstrapPrivateExpInternalGates", "WAGRGateSet("):
    if unsafe in launcher:
        errors.append(f"dogfood launcher still manufactures eligibility via {unsafe}")

employee = read("src/Hooks/WAGREmployeeHooks.xm")
native_menu = read("src/Hooks/WAGRNativeDevMenuHooks.xm")
gate_hooks = read("src/Hooks/WAGRGateHooks.xm")
for text, location, forbidden in (
    (employee, "WAGREmployeeHooks.xm", "%hook WAServerProperties"),
    (employee, "WAGREmployeeHooks.xm", "WAGRInstallKnownEmployeeHook"),
    (native_menu, "WAGRNativeDevMenuHooks.xm", "WAGRPrepareNativeInternalSurfaces"),
    (native_menu, "WAGRNativeDevMenuHooks.xm", 'WAGRGateSet(selector, YES)'),
    (gate_hooks, "WAGRGateHooks.xm", '@{ @"class": @"WAServerProperties", @"sel": @"isInternalUser"'),
):
    if forbidden in text:
        errors.append(f"{location} still synthesizes internal/employee eligibility via {forbidden}")

legacy_root = read("src/Menu/WAGRSurfaceListVC.m")
for obsolete in ("Abrir Private Experimentation", "Abrir Menu Developer Nativo",
                 "WAGRLaunchPrivateExperimentationDebug"):
    if obsolete in legacy_root:
        errors.append(f"legacy root still presents absent launcher path {obsolete}")
for required in ("Launcher dogfood", "https://fburl.com/df_iphone"):
    if required not in legacy_root:
        errors.append(f"legacy root missing verified dogfood label/evidence {required}")

fast_build = read("build-fast.sh")
if 'resources/waab_family_catalog_26_40_10.json' not in fast_build:
    errors.append("build-fast.sh does not embed the IPA family catalog for sideload")

secret_menus = read("src/Menu/WAGRSecretMenusVC.m")
if "Modo Internal / Employee" in secret_menus or "WAGRSecretInternalRuntimeOverrides" in secret_menus:
    errors.append("SecretMenus still exposes local internal/employee eligibility mutation")
account_eligibility = read("src/Hooks/WAGRAccountEligibilityHooks.xm")
for forbidden in ("MSHookMessageEx", "hook_eligibilityBool", "return YES;"):
    if forbidden in account_eligibility:
        errors.append(f"AccountEligibility hooks are not diagnostic-only: {forbidden}")
global_stub = read("src/Hooks/WAGRGlobalGateStub.xm")
if "WAGREligibilityOverrideIsProtectedCString" not in global_stub:
    errors.append("GlobalGateStub does not apply the central eligibility protection policy")

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
