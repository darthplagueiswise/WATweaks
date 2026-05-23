#!/usr/bin/env python3
"""
Generate WATweaks runtime inventory JSON files from a WhatsApp main executable
and SharedModules.framework binary.

Requires: lief, capstone
Usage:
  python3 scripts/generate_runtime_inventory.py \
    --shared /path/to/SharedModules --main /path/to/WhatsApp \
    --out resources/runtime

The output is intentionally inventory-only. It records surfaces, selectors,
controllers, dependencies, and validation evidence; it does not create runtime
bypass patches or entitlement-forcing hooks.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

BOOLISH_RE = re.compile(
    r"^(is|has|can|should|does|allows|supports|requires|needs)[A-Z_].*|.*(Enabled|Disabled|Eligible|Available|Active|Installed|Supported|Allowed|Blocked|KillSwitch|Killswitch)$"
)

TARGET_FILES = [
    "WAABProperties.json",
    "WAContext.json",
    "WAAura.json",
    "WAMobileConfig.json",
    "WAFoa.json",
    "WABiz.json",
    "WAServerProperties.json",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def cstrings_from_bytes(data: bytes, min_len: int = 3) -> List[str]:
    out: List[str] = []
    start: Optional[int] = None
    for i, b in enumerate(data + b"\x00"):
        printable = 32 <= b < 127
        if printable:
            if start is None:
                start = i
        elif start is not None:
            if i - start >= min_len:
                try:
                    out.append(data[start:i].decode("utf-8", "ignore"))
                except Exception:
                    pass
            start = None
    return out


@dataclass
class BinaryInfo:
    label: str
    path: Path
    lief_binary: Any
    arch: str
    file_size: int
    sha256: str
    strings: List[str]
    string_set: set[str]
    method_names: List[str]
    symbols: List[str]
    first_text_instructions: List[str]

    def has(self, needle: str) -> bool:
        return needle in self.string_set or any(needle in s for s in self.symbols)

    def find_strings(self, pattern: str, limit: int = 200) -> List[str]:
        rx = re.compile(pattern)
        result = []
        seen = set()
        for s in self.strings:
            if s in seen:
                continue
            if rx.search(s):
                seen.add(s)
                result.append(s)
                if len(result) >= limit:
                    break
        return result


def section_bytes(binary: Any, name: str) -> bytes:
    for sec in binary.sections:
        if sec.name == name:
            return bytes(sec.content)
    return b""


def load_binary(label: str, path: Path) -> BinaryInfo:
    macho = lief.parse(str(path))
    if macho is None:
        raise RuntimeError(f"LIEF could not parse {path}")
    arch = str(getattr(macho.header, "cpu_type", "unknown"))
    raw_strings = []
    for sec_name in ("__objc_methname", "__cstring", "__swift5_types", "__swift5_proto", "__swift5_fieldmd"):
        raw_strings.extend(cstrings_from_bytes(section_bytes(macho, sec_name)))
    # Keep generation bounded: targeted Swift/ObjC names used here are present in __cstring/__objc_methname.
    strings = sorted(set(raw_strings))
    meth = sorted(set(cstrings_from_bytes(section_bytes(macho, "__objc_methname"))))
    symbols = sorted({getattr(sym, "name", "") for sym in macho.symbols if getattr(sym, "name", "")})

    text = section_bytes(macho, "__text")[:64]
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    first_instr = [f"0x{i.address:x}: {i.mnemonic} {i.op_str}".strip() for i in md.disasm(text, 0)][:8]

    return BinaryInfo(
        label=label,
        path=path,
        lief_binary=macho,
        arch=arch,
        file_size=path.stat().st_size,
        sha256=sha256_file(path),
        strings=strings,
        string_set=set(strings),
        method_names=meth,
        symbols=symbols,
        first_text_instructions=first_instr,
    )


def bool_getters_present(binaries: Sequence[BinaryInfo], selectors: Sequence[str]) -> List[Dict[str, Any]]:
    rows = []
    for sel in selectors:
        found_in = []
        for b in binaries:
            if sel in b.string_set or sel in b.method_names or any(sel in s for s in b.symbols):
                found_in.append(b.label)
        rows.append({"selector": sel, "present_in": found_in, "confirmed": bool(found_in)})
    return rows


def class_entry(name: str, source: str, role: str, binaries: Sequence[BinaryInfo], selectors: Sequence[str] = (), controllers: Sequence[str] = (), dependencies: Sequence[str] = ()) -> Dict[str, Any]:
    present_in = [b.label for b in binaries if b.has(name)]
    return {
        "class": name,
        "source": source,
        "role": role,
        "present_in": present_in,
        "confirmed": bool(present_in),
        "properties": [],
        "boolGetters": bool_getters_present(binaries, selectors),
        "controllers": list(controllers),
        "dependencies": list(dependencies),
    }


def load_existing_waab_catalog(root: Path) -> Dict[str, Any]:
    p = root / "resources" / "waab_selected_categories_bool_only_catalog.json.gz"
    if not p.exists():
        return {"available": False, "flags": [], "summary_by_category": {}}
    with gzip.open(p, "rt", encoding="utf-8") as f:
        d = json.load(f)
    return {
        "available": True,
        "source_file": str(p.relative_to(root)),
        "total": d.get("total"),
        "selected_categories": d.get("selected_categories", []),
        "summary_by_category": d.get("summary_by_category", {}),
        "flags": d.get("flags", []),
    }


def pick_flags(catalog: Mapping[str, Any], groups: Sequence[str], needle_rx: Optional[str] = None, limit: int = 250) -> List[Dict[str, Any]]:
    flags = catalog.get("flags", []) if catalog.get("available") else []
    rx = re.compile(needle_rx, re.I) if needle_rx else None
    out = []
    for f in flags:
        if groups and not (set(groups) & set(f.get("groups", []))):
            continue
        if rx and not rx.search(f.get("key", "")):
            continue
        out.append({
            "key": f.get("key"),
            "title": f.get("title"),
            "value_type": f.get("value_type"),
            "groups": f.get("groups", []),
            "override_key": f.get("override_key"),
            "source": f.get("source"),
            "confidence": f.get("confidence"),
            "occurrence_count": f.get("occurrence_count"),
        })
        if len(out) >= limit:
            break
    return out


def metadata(shared: BinaryInfo, main: BinaryInfo) -> Dict[str, Any]:
    return {
        "schema_version": 1,
        "generator": "scripts/generate_runtime_inventory.py",
        "tools": {
            "lief": getattr(lief, "__version__", "unknown"),
            "capstone": "imported",
        },
        "binaries": {
            shared.label: {
                "path_basename": shared.path.name,
                "size": shared.file_size,
                "sha256": shared.sha256,
                "arch": shared.arch,
                "objc_method_names": len(shared.method_names),
                "unique_strings": len(shared.strings),
                "text_probe": shared.first_text_instructions,
            },
            main.label: {
                "path_basename": main.path.name,
                "size": main.file_size,
                "sha256": main.sha256,
                "arch": main.arch,
                "objc_method_names": len(main.method_names),
                "unique_strings": len(main.strings),
                "text_probe": main.first_text_instructions,
            },
        },
        "note": "Inventory-only. Use this as a grouping/mapping layer before backup/export. Do not assume a selector is safely hookable until runtime method ownership and type encoding are validated in-process.",
    }


def write_json(out: Path, name: str, data: Dict[str, Any]) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / name).write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=False) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shared", required=True, type=Path)
    ap.add_argument("--main", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--project-root", type=Path, default=Path.cwd())
    args = ap.parse_args()

    shared = load_binary("SharedModules", args.shared)
    main_bin = load_binary("WhatsApp", args.main)
    bins = [shared, main_bin]
    meta = metadata(shared, main_bin)
    catalog = load_existing_waab_catalog(args.project_root)

    waserver_selectors = [
        "userContext", "setUserContext:", "configureUserContext:", "isInternalUser",
        "paymentsUPIOverdraftAccountEnabled", "listMessageReceptionDisabled", "frequentlyForwardedGroupSettingEnabled",
    ]
    write_json(args.out, "WAServerProperties.json", {
        **meta,
        "family": "WAServerProperties",
        "grouping": "Master gate and bridge into WAContext/WAContextMain.",
        "runtime_tree": ["WAServerProperties", "userContext", "WAContext", "WAContextMain"],
        "classes": [class_entry("WAServerProperties", "SharedModules", "central server/internal/dogfood gate surface", bins, waserver_selectors, dependencies=["WAContext", "WAContextMain", "WAABProperties"])],
        "boolGetters": bool_getters_present(bins, ["isInternalUser", "paymentsUPIOverdraftAccountEnabled", "listMessageReceptionDisabled", "frequentlyForwardedGroupSettingEnabled"]),
        "dependencies": ["WAContext", "WAContextMain", "WAABProperties"],
    })

    write_json(args.out, "WAContext.json", {
        **meta,
        "family": "WAContext",
        "grouping": "WAContext and WAContextMain belong to one menu family; WAContextMain should be nested under ContextMain Runtime, not shown as a separate top-level menu.",
        "menu_sections": ["Context Core", "Context Services", "Context Managers", "Context Experiments", "ContextMain Runtime"],
        "classes": [
            class_entry("WAContext", "SharedModules", "base context bridge", bins, ["accountUUID", "notificationConfiguration", "safeMode", "fullyPrepared"], dependencies=["WAServerProperties", "WAContextMain"]),
            class_entry("WAContextObjectProvider", "SharedModules", "object provider", bins),
            class_entry("WAContextDependencyInversion", "SharedModules", "dependency inversion container", bins),
            class_entry("WAContextDependencyInversionNoop", "SharedModules", "no-op dependency container", bins),
            class_entry("WAContextDependencyInversionShared", "SharedModules", "shared dependency container", bins),
            class_entry("WAContextMain", "WhatsApp", "main runtime context with app managers/services", bins, controllers=["WAContextMainObjectProvider", "WAContextMainFactory"], dependencies=["WAABProperties", "WABizManagerMain", "notificationLogger", "privacyPolicyManager", "paymentBannerManager"]),
        ],
        "main_runtime_hints": main_bin.find_strings(r"(contactsManager|chatManager|syncManager|registrationManager|statusExpirationManager|notificationLogger|historySyncService|paymentBannerManager|privacyPolicyManager|WAContextMain)", limit=120),
    })

    aura_selectors = [
        "isUserEligible", "isUserEligibleFor:", "isBenefitActive", "isAppThemesEnabled", "isAppIconsEnabled",
        "isRingtonesEnabled", "isStickersEnabled", "isEnhancedListsEnabled", "isExtendedPinnedChatEnabled",
        "isAppIconMultiAccountSupportEnabled", "isAppThemeNewChatPreviewFlowEnabled",
    ]
    write_json(args.out, "WAAura.json", {
        **meta,
        "family": "WAAura",
        "grouping": "Split into gating, foundation/preferences, provider layer, and executable controllers.",
        "classes": [
            class_entry("WAAuraGating", "SharedModules", "module namespace", bins, dependencies=["WAAuraFoundation", "AuraPreferences", "AuraProviding"]),
            class_entry("WAAuraGating.AuraGating", "SharedModules", "benefit/subscription eligibility getter surface", bins, aura_selectors, dependencies=["WAAuraGating.GatedBenefitProvider", "WAAuraGating.GatedSubscriptionProvider"]),
            class_entry("WAAuraGating.GatedBenefitProvider", "SharedModules", "benefit provider", bins, dependencies=["WAAuraGating.AuraGating"]),
            class_entry("WAAuraGating.GatedSubscriptionProvider", "SharedModules", "subscription provider", bins, dependencies=["WAAuraGating.AuraGating"]),
            class_entry("WAAuraFoundation", "SharedModules", "theme foundation namespace", bins, dependencies=["WAAuraFoundation.AppThemeManager"]),
            class_entry("WAAuraFoundation.AppThemeManager", "SharedModules", "theme manager", bins),
            class_entry("WAAura.AppThemesViewController", "WhatsApp", "native app theme picker/controller", bins, ["presentationControllerDidDismiss:", "wallpaperPreviewController:didSelectChatTheme:"], dependencies=["AuraPreferences", "AuraUIComponentProvider"]),
            class_entry("WAAura.AppIconsViewController", "WhatsApp", "native app icon picker/controller", bins, dependencies=["AuraPreferences", "AuraUIComponentProvider"]),
            class_entry("AuraButtonFactory", "WhatsApp", "Aura UI button factory", bins),
            class_entry("AuraSheetPresenter", "WhatsApp", "Aura sheet presentation", bins),
            class_entry("AuraUIComponentProvider", "WhatsApp", "Aura UI component provider", bins),
            class_entry("AuraPreferences", "WhatsApp", "Aura preferences layer", bins),
            class_entry("AuraProviding", "WhatsApp", "provider protocol/surface", bins),
            class_entry("AuraProvidingAccessor", "WhatsApp", "provider accessor", bins),
        ],
        "boolGetters": bool_getters_present(bins, aura_selectors),
        "waab_flags": pick_flags(catalog, ["ui_ux", "business"], r"aura|wa_plus|subscription|ringtone|sticker|theme|icon|premium", 200),
        "controllers": ["WAAppearanceSettingsViewController", "WAAura.AppThemesViewController", "WAAura.AppIconsViewController"],
        "controller_selectors": bool_getters_present(bins, ["makeAppIconViewControllerWithContext:", "makeAppThemeViewControllerWithContext:", "setupAutoplaySettingsSectionIn:userContext:entryPoint:", "setupChatThemeSectionIn:userContext:entryPoint:"]),
    })

    foa_selectors = ["isFacebookAppInstalled", "isInstagramAppInstalled", "isThreadsAppInstalled", "isMetaAIAppInstalled", "waSourceSurfaceConstFeedUfi", "waSourceSurfaceConstReelsUfi"]
    write_json(args.out, "WAFoa.json", {
        **meta,
        "family": "FOA",
        "grouping": "Family-of-Apps install/routing utilities should be separate from WAContext and WAAB.",
        "menu_sections": ["Instagram", "Facebook", "Threads", "Meta AI", "Cross App Routing"],
        "classes": [class_entry("WAFoaAppUtilities", "SharedModules", "FOA install/routing utility surface", bins, foa_selectors, dependencies=["WAABProperties", "WAContext"])],
        "boolGetters": bool_getters_present(bins, ["isFacebookAppInstalled", "isInstagramAppInstalled", "isThreadsAppInstalled", "isMetaAIAppInstalled"]),
    })

    write_json(args.out, "WABiz.json", {
        **meta,
        "family": "WABiz",
        "grouping": "Business stack has its own tree and also consumes WAABProperties internally.",
        "menu_sections": ["Biz Core", "Biz Profiles", "Biz Roles", "Biz Entry Points", "Biz Storage", "Biz Caches", "Biz ABProperties"],
        "classes": [
            class_entry("WABiz.BizManager", "SharedModules/Swift", "business manager surface observed by runtime browser", bins, ["entryPointInfoForJID:", "isCTWAMerchant:", "conversionInfoFor:"], dependencies=["WAABProperties", "bizStorage", "rolesCache", "profilesCache", "verifiedNameInfosCache", "automatedTypesCache"]),
            class_entry("WABiz.BizStorage", "SharedModules/Swift", "business storage", bins),
            class_entry("WABiz.BizProfile", "SharedModules/Swift", "business profile model", bins),
            class_entry("WABiz.BizRole", "SharedModules/Swift", "business role model", bins),
            class_entry("WABiz.EntryPointConversionProvider", "SharedModules/Swift", "conversion/entrypoint layer", bins),
            class_entry("WABizManagerMain", "WhatsApp", "main executable business manager bridge", bins, dependencies=["WAContextMain", "WAABProperties"]),
            class_entry("WACTWABizManagerObjCFacade", "WhatsApp", "CTWA ObjC bridge", bins, dependencies=["WAContextMain"]),
        ],
        "boolGetters": bool_getters_present(bins, ["isCTWAMerchant:"]),
        "waab_flags": pick_flags(catalog, ["business"], None, 250),
        "evidence_strings": shared.find_strings(r"^WABiz(\.|[A-Z])", limit=200),
    })

    write_json(args.out, "WAABProperties.json", {
        **meta,
        "family": "WAABProperties",
        "grouping": "AB property surface consumed by WAAura, WABiz, Settings rows, and many app systems. This file summarizes the existing bool-only catalog rather than duplicating all flags.",
        "classes": [
            class_entry("WAABProperties", "SharedModules", "primary AB properties accessor", bins, ["boolForKey:defaultValue:", "stringForKey:defaultValue:", "integerForKey:defaultValue:", "doubleForKey:defaultValue:"], dependencies=["WAContext", "WAServerProperties"]),
            class_entry("WAABPropertiesImpl", "SharedModules", "implementation surface", bins),
            class_entry("FOAWAABPropertiesImpl", "SharedModules/WhatsApp", "FOA-specific AB implementation candidate", bins),
        ],
        "existing_catalog": {k: v for k, v in catalog.items() if k != "flags"},
        "selected_summaries": {
            "aura": pick_flags(catalog, ["ui_ux", "business"], r"aura|wa_plus|subscription|theme|icon|ringtone|sticker|premium", 80),
            "biz": pick_flags(catalog, ["business"], None, 80),
            "foa": pick_flags(catalog, ["ui_ux", "business"], r"foa|facebook|instagram|threads|meta_ai|crosspost", 80),
            "internal": pick_flags(catalog, ["dogfood_employee_internal", "experimentation"], r"internal|employee|dogfood|debug|server", 80),
        },
    })

    write_json(args.out, "WAMobileConfig.json", {
        **meta,
        "family": "WAMobileConfig",
        "grouping": "MobileConfig/MetaConfig/FeatureFlag terminology observed around WAAB and experiment systems. Keep separate from WAAB until runtime ownership is confirmed.",
        "classes": [],
        "strings": {
            "SharedModules": shared.find_strings(r"(MobileConfig|mobileConfig|MetaConfig|FeatureFlag|ABProp|ABProperties|Experiment)", limit=250),
            "WhatsApp": main_bin.find_strings(r"(MobileConfig|mobileConfig|MetaConfig|FeatureFlag|ABProp|ABProperties|Experiment)", limit=250),
        },
        "waab_experiment_flags": pick_flags(catalog, ["experimentation"], None, 250),
        "dependencies": ["WAABProperties", "WAServerProperties", "WAContext"],
    })

    manifest = {
        **meta,
        "files": TARGET_FILES,
        "recommended_flow": ["Runtime Menu", "Inventory JSON", "NSUserDefaults mapping", "Backup/Restore JSON"],
    }
    write_json(args.out, "manifest.json", manifest)
    print(f"Wrote {len(TARGET_FILES) + 1} files to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
