#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
errors = []

def need(path, text, label=None):
    p = root / path
    if not p.exists():
        errors.append(f"ERRO: missing {path}")
        return
    s = p.read_text(encoding="utf-8", errors="ignore")
    if text not in s:
        errors.append(f"ERRO: {label or text} not found in {path}")

need("src/Menu/WAGRABPropsRootVC.m", "applyHooks", "applyHooks")
need("src/Menu/WAGRABPropsRootVC.m", "WAGRWAABInstallHooksForExecutable", "Executable WAAB scan")
need("src/Menu/WAGRABPropsRootVC.m", "WAGRWAABInstallHooksForSharedModules", "SharedModules WAAB scan")
need("src/Menu/WAGRABPropsRootVC.m", "WAGRWAABInstallHooksForAllRuntimeImages", "All runtime WAAB scan")
need("src/Hooks/WAGRGateHooks.xm", "WAGRWAABInstallHooksForExecutable", "WAGRWAABInstallHooksForExecutable implementation")
need("src/Hooks/WAGRGateHooks.xm", "WAGRWAABInstallHooksForSharedModules", "WAGRWAABInstallHooksForSharedModules implementation")
need("src/Hooks/WAGRGateHooks.xm", "objc_copyClassList", "on-demand class scan")
need("src/Hooks/WAGRGateHooks.xm", "class_getImageName", "runtime image split")

if errors:
    print("\n".join(errors))
    sys.exit(1)

print("WATweaks WAAB on-demand split runtime validation OK")
