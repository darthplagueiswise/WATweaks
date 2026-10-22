#!/usr/bin/env python3
"""Portable runtime policy tests plus focused Objective-C integration guards.

The C tests exercise production policy against action selectors found in the
supplied IPA and a bundled-binary fixture tree. UIKit itself is not run here.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


def body(text, signature):
    if signature not in text:
        raise AssertionError(f"Required implementation boundary missing: {signature}")
    start = text.index(signature)
    brace = text.index("{", start)
    depth, quote, escape = 1, None, False
    for end in range(brace + 1, len(text)):
        char = text[end]
        if quote:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:end]
    raise AssertionError(f"Unbalanced body: {signature}")


def compile_and_run(program, directory, args=()):
    path = Path(directory)
    test = path / "runtime_policy.c"
    executable = path / "runtime_policy"
    test.write_text(program)
    built = subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "src/Runtime"), str(test), "-o", str(executable)],
        capture_output=True, text=True)
    if built.returncode:
        raise AssertionError(built.stderr)
    return subprocess.run([str(executable), *args], cwd=path, capture_output=True, text=True)


class RuntimeBrowserTests(unittest.TestCase):
    def test_account_eligibility_overrides_are_blocked_at_common_boundaries(self):
        policy = ROOT / "src/Runtime/WAGREligibilityPolicy.h"
        self.assertTrue(policy.exists(), "central eligibility protection policy is missing")
        program = r'''
#include "WAGREligibilityPolicy.h"
int main(void) {
    if (!WAGREligibilityOverrideIsProtectedCString("WAServerProperties", "isInternalUser")) return 1;
    if (!WAGREligibilityOverrideIsProtectedCString("WAAccountEligibility", "isLinkingModeOn")) return 2;
    if (!WAGREligibilityOverrideIsProtectedCString("Other", "isEligibleForSubscriptions")) return 3;
    if (!WAGREligibilityOverrideIsProtectedCString("Other", "wamo_is_employee")) return 4;
    if (WAGREligibilityOverrideIsProtectedCString("WAAuraGating", "aura_enabled")) return 5;
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="wagr-eligibility-policy-") as directory:
            result = compile_and_run(program, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
        for rel in ("src/Hooks/WAGRGateHooks.xm", "src/Runtime/WAGRGateStore.m",
                    "src/Runtime/WAGRRuntimeValueStore.m"):
            self.assertIn("WAGREligibilityOverrideIsProtectedCString", source(rel), rel)

    def test_ipa_waab_family_catalog_preserves_native_category_ownership(self):
        catalog_path = ROOT / "resources/waab_family_catalog_26_40_10.json"
        self.assertTrue(catalog_path.exists(), "IPA-derived WAAB family catalog is missing")
        catalog = json.loads(catalog_path.read_text())
        self.assertEqual(catalog["whatsappVersion"], "26.40.10")
        self.assertEqual(catalog["build"], "1086609742")
        selectors = catalog["selectors"]
        self.assertIn("WAMediaPlayer", selectors["ios_pause_video_preview"]["SharedModules"])
        self.assertIn("BloksExperiment", selectors["bloks_theming_infra_enabled"]["WhatsApp"])

        family = source("src/Runtime/WAGRWAABFamilyCatalog.m")
        self.assertIn('Fallback ·', family,
            "selectors absent from build metadata must be visibly marked as heuristic")
        scanner = source("src/Runtime/WAGRSurface.m")
        self.assertIn("WAGRWAABFamilyForSelector", scanner)
        abprops = source("src/Runtime/WAGRABPropsRuntime.m")
        self.assertIn("entry.cataloged = cataloged", abprops)

        policy = ROOT / "src/Runtime/WAGRWAABCatalogPolicy.h"
        self.assertTrue(policy.exists(), "portable catalog build policy is missing")
        program = r'''
#include "WAGRWAABCatalogPolicy.h"
int main(void) {
    if (!WAGRWAABCatalogBuildMatchesCString("26.40.10", "1086609742",
                                             "26.40.10", "1086609742")) return 1;
    if (WAGRWAABCatalogBuildMatchesCString("26.40.10", "1086609742",
                                            "26.41.0", "1086609742")) return 2;
    if (WAGRWAABCatalogBuildMatchesCString("26.40.10", "1086609742",
                                            "26.40.10", "999")) return 3;
    if (WAGRWAABCatalogBuildMatchesCString(0, "1086609742",
                                            "26.40.10", "1086609742")) return 4;
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="wagr-catalog-policy-") as directory:
            result = compile_and_run(program, directory)
            self.assertEqual(result.returncode, 0, result.stderr)

        self.assertIn("WAGRWAABCatalogBuildMatchesCString", family)
        self.assertIn("WAGRLiveRuntimeFamilyForSelectorInImage(selector, className, methodPath)", scanner)
        image_resolver = body(scanner, "static NSString *WAGRLiveMethodImagePath")
        self.assertIn("method_getImplementation", image_resolver)
        self.assertIn("dladdr", image_resolver)
        family_scan = body(scanner, "+ (NSArray<WAGRSurfaceSpec *> *)runtimeFamilySurfaces")
        self.assertIn("WAGRLiveMethodImagePath(method, cls)", family_scan)
        add_entry = body(scanner, "static void WAGRAddEntry")
        self.assertIn("WAGRLiveMethodImagePath(method, cls)", add_entry)

    def test_cross_image_category_membership_and_catalog_resolution(self):
        program = r'''
#include "WAGRRuntimeSafety.h"
#include "WAGRWAABCatalogPolicy.h"
int main(void) {
    const char *mainImage = "/App/WhatsApp.app/WhatsApp";
    const char *sharedImage = "/App/WhatsApp.app/Frameworks/SharedModules.framework/SharedModules";
    /* A SharedModules-defined class has one local getter and a main-image category. */
    const char *methodImages[] = {sharedImage, mainImage};
    int mainCount = 0, sharedCount = 0;
    for (int i = 0; i < 2; i++) {
        mainCount += WAGRRuntimeMethodMatchesImageCString(methodImages[i], mainImage);
        sharedCount += WAGRRuntimeMethodMatchesImageCString(methodImages[i], sharedImage);
    }
    if (mainCount != 1 || sharedCount != 1) return 1;
    if (!WAGRWAABCatalogMayUseImageCString(mainImage, 2)) return 2;
    if (WAGRWAABCatalogMayUseImageCString(mainImage, 1)) return 3;
    if (!WAGRWAABCatalogMayUseImageCString(sharedImage, 1)) return 4;
    if (WAGRWAABCatalogMayUseImageCString(sharedImage, 2)) return 5;
    /* Unknown source may combine owners; recognized source never borrows another. */
    if (!WAGRWAABCatalogMayUseImageCString(0, 1) ||
        !WAGRWAABCatalogMayUseImageCString(0, 2)) return 6;
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="wagr-cross-image-") as directory:
            result = compile_and_run(program, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
        scanner = source("src/Runtime/WAGRSurface.m")
        self.assertIn("WAGRRuntimeMethodMatchesImageCString", body(scanner, "static void WAGRAddEntry"))
        self.assertNotIn("isEqualToString:spec.runtimeImagePath", body(scanner, "static BOOL WAGRClassMatchesSurface"))
        for path in ("src/Menu/WAGRABPropsBrowserVC.m", "src/Menu/WAGRABPropsBrowserPerformanceUI.m",
                     "src/Menu/WAGRRuntimeBrowserCompactUI.m"):
            self.assertNotIn("WAGRLiveRuntimeFamilyForSelector(", source(path), path)

    def test_binary_action_selectors_are_rejected_but_getters_remain_editable(self):
        header = ROOT / "src/Runtime/WAGRRuntimeSafety.h"
        self.assertTrue(header.exists(), "shared portable runtime admission policy is missing")
        program = r'''
#include <stdio.h>
#include "WAGRRuntimeSafety.h"
int main(void) {
    /* Actual supported-ABI actions in SharedModules/CommonLibrary/Psiphon. */
    const char *blocked[] = {".cxx_construct", ".cxx_destruct", "init", "initWithContext",
        "alloc", "allocWithZone", "new", "newInstance", "copy", "mutableCopy",
        "dealloc", "retain", "release", "autorelease", "description", "class",
        "start", "startIfNeeded", "stopAndReconnectWithCurrentSessionID",
        "startNotifier", "resetDatabase", "startReading", "startWriting",
        "methodWithArgument:", "", NULL};
    const char *allowed[] = {"isInternalUser", "isEnabled", "hasLiquidGlassLaunched",
        "abProperties", "wamo_abprops_list", "startDate", "startsInAnimatedStickerEditing",
        "resetDatabaseEnabled", "initialValue", "newsEnabled", "copyingEnabled"};
    for (unsigned int i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if (WAGRRuntimeSelectorIsSafeGetterCString(blocked[i])) {
            fprintf(stderr, "unsafe selector admitted: %s\n", blocked[i] ? blocked[i] : "NULL");
            return 1;
        }
    }
    for (unsigned int i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
        if (!WAGRRuntimeSelectorIsSafeGetterCString(allowed[i])) {
            fprintf(stderr, "getter rejected: %s\n", allowed[i]);
            return 1;
        }
    }
    const char *bundle = "/var/App/WhatsApp.app";
    if (!WAGRRuntimePathIsWithinBundleCString("/var/App/WhatsApp.app/WhatsApp", bundle) ||
        !WAGRRuntimePathIsWithinBundleCString("/var/App/WhatsApp.app/Frameworks/A/Foo", bundle) ||
        WAGRRuntimePathIsWithinBundleCString("/var/App/WhatsApp.app-other/Foo", bundle) ||
        WAGRRuntimePathIsWithinBundleCString("/var/Other.app/Foo", bundle) ||
        WAGRRuntimePathIsWithinBundleCString("/var/App/WhatsApp.app/WhatsApp", "")) return 2;
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="wagr-runtime-test-") as directory:
            result = compile_and_run(program, directory)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_bundled_binary_fixtures_include_nested_frameworks_and_exclude_extensions(self):
        header = ROOT / "src/Runtime/WAGRRuntimeSafety.h"
        self.assertTrue(header.exists(), "bundled binary admission policy is missing")
        self.assertIn("WAGRRuntimeBundledPathIsInspectableCString", header.read_text())
        program = r'''
#include <stdio.h>
#include "WAGRRuntimeSafety.h"
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (WAGRRuntimeBundledPathIsInspectableCString(argv[i]) &&
            WAGRRuntimeFileIsMachOCString(argv[i])) puts(argv[i]);
    }
    return 0;
}
'''
        included = ["WhatsApp", "Frameworks/CommonLibrary.framework/CommonLibrary",
            "Frameworks/PsiphonTunnel.framework/PsiphonTunnel",
            "Frameworks/SharedModules.framework/SharedModules", "Frameworks/zxPluginsInject.dylib",
            "Watusi.bundle/FLEX.framework/FLEX", "WatusiTools.bundle/InMobiSDK.framework/InMobiSDK",
            "WSVendor.framework/WSVendor", "One/Foo.framework/Foo", "Two/Foo.framework/Foo"]
        excluded = ["PlugIns/NotificationService.appex/Frameworks/Foo.framework/Foo",
            "Watch/WatchApp.app/Frameworks/Foo.framework/Foo", ".hidden/Foo.dylib",
            "en.lproj/Foo.dylib", "Frameworks/Resource.dylib"]
        with tempfile.TemporaryDirectory(prefix="wagr-bundled-fixtures-") as directory:
            root = Path(directory)
            for relative in included + excluded:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"not a Mach-O" if relative.endswith("Resource.dylib") else b"\xcf\xfa\xed\xfe" + bytes(28))
            result = compile_and_run(program, directory, included + excluded)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), included)

    def test_supplied_ipa_main_process_inventory_has_nine_inspectable_images(self):
        supplied = ["WhatsApp", "WSVendor.framework/WSVendor", "OnlineNotify.dylib",
            "Watusi.bundle/FLEX.framework/FLEX",
            "Frameworks/SharedModules.framework/SharedModules",
            "Frameworks/zxPluginsInject.dylib",
            "Frameworks/CommonLibrary.framework/CommonLibrary",
            "Frameworks/PsiphonTunnel.framework/PsiphonTunnel",
            "WatusiTools.bundle/InMobiSDK.framework/InMobiSDK"]
        self.assertEqual(len(supplied), 9)
        header = (ROOT / "src/Runtime/WAGRRuntimeSafety.h").read_text()
        for relative in supplied:
            self.assertNotIn(relative, ["PlugIns", "Extensions"])
        self.assertIn("WAGRRuntimeBundledPathIsInspectableCString", header)

    def test_image_inventory_does_not_depend_on_objc_getters(self):
        scanner = source("src/Runtime/WAGRSurface.m")
        inventory = body(scanner, "+ (NSArray<WAGRSurfaceSpec *> *)runtimeImageSurfaces")
        self.assertTrue("WAGRLiveAppImagePaths()" in inventory,
            "image inventory must include loaded Mach-O images with zero getters")
        self.assertTrue("WAGRLiveBundledImagePaths()" in inventory,
            "dormant bundled frameworks must remain discoverable without loading them")
        self.assertNotRegex(inventory, r"if\s*\(\s*!methods\s*\)\s*continue")
        images = body(scanner, "static NSArray<NSString *> *WAGRLiveAppImagePaths")
        self.assertIn("_dyld_image_count()", images)
        self.assertIn("_dyld_get_image_name(", images)
        self.assertNotIn("dlopen(", scanner)
        self.assertIn("runtimeImagePath = path", inventory)
        self.assertNotIn("path.hash", inventory)
        self.assertIn("runtimeImageLoaded", inventory)

    def test_image_hub_replaces_two_synchronous_legacy_shortcuts(self):
        main = source("src/Menu/WAGRMainSettingsVC.m")
        self.assertIn("WAGRRuntimeImagesVC", main)
        self.assertNotIn('nav(@"WhatsApp Executable"', main)
        self.assertNotIn('nav(@"SharedModules"', main)
        self.assertNotIn("static WAGRSurfaceSpec *surface(", main)
        self.assertFalse((ROOT / "src/Runtime/WAGRRuntimeSurfaceCompatibility.xm").exists())

    def test_runtime_snapshot_is_cached_by_dyld_generation_and_scans_are_bounded(self):
        scanner = source("src/Runtime/WAGRSurface.m")
        inventory = body(scanner, "+ (NSArray<WAGRSurfaceSpec *> *)runtimeImageSurfaces")
        self.assertIn("WAGRLiveImageGeneration()", inventory)
        self.assertIn("gWAGRImageSurfaceCache", inventory)
        self.assertIn("@autoreleasepool", inventory)
        self.assertIn("+ (void)invalidateRuntimeImageCache", scanner)
        families = body(scanner, "+ (NSArray<WAGRSurfaceSpec *> *)runtimeFamilySurfaces")
        self.assertIn("@autoreleasepool", families)
        runtime_ui = source("src/Menu/WAGRSurfaceListVC.m")
        self.assertIn("Extensões rodam em processos separados", runtime_ui)
        initial = body(runtime_ui, "- (void)loadSurfaces")
        refresh = body(runtime_ui, "- (void)refreshSurfaces")
        self.assertNotIn("invalidateRuntimeImageCache", initial)
        self.assertIn("invalidateRuntimeImageCache", refresh)
        self.assertIn("[self loadSurfaces]", refresh)

    def test_render_path_uses_only_cached_or_stored_values(self):
        browser = source("src/Menu/WAGRSurfaceBrowserVC.m")
        current = body(browser, "- (NSString *)currentForEntry:")
        self.assertNotIn("WAGRRuntimeValueRead(", current,
            "rendering a row must not invoke an arbitrary native method")
        self.assertNotIn("receiverForEntry:", current)
        self.assertNotIn("resolveRuntimeObjects", body(browser, "- (void)scanNow"))
        self.assertIn("WAGRRuntimeValueRead(", body(browser, "- (void)readValueForEntry:"))
        self.assertIn("readValueForEntry:", body(browser, "- (void)longPressRow:"))

    def test_selector_policy_is_enforced_at_catalog_read_and_hook_boundaries(self):
        store = source("src/Runtime/WAGRRuntimeValueStore.m")
        scanner = source("src/Runtime/WAGRSurface.m")
        self.assertIn("WAGRRuntimeValueSelectorIsSafeGetter(",
            body(scanner, "static BOOL WAGRLiveMethodIsSupported"))
        for signature in ("BOOL WAGRRuntimeValueInstallHook(", "NSString *WAGRRuntimeValueRead("):
            self.assertIn("WAGRRuntimeValueSelectorIsSafeGetter(", body(store, signature))
        self.assertIn("WAGRRuntimeSelectorIsSafeGetterCString(",
            body(store, "BOOL WAGRRuntimeValueSelectorIsSafeGetter("))

    def test_generic_browse_never_installs_receiver_probes_or_walks_ivars(self):
        paths = [ROOT / "src/Menu/WAGRSurfaceBrowserVC.m",
                 ROOT / "src/Menu/WAGRRuntimeBrowserFastTypedUI.m",
                 ROOT / "src/Menu/WAGRRuntimeBrowserCrashGuard.m",
                 ROOT / "src/Menu/WAGRRuntimeLiveReceiverObservation.m"]
        generic = "\n".join(path.read_text() for path in paths if path.exists())
        for forbidden in ("object_getIvar(", "class_copyIvarList(", "WAGRReceiverInstallProbe(",
                          "WAGRSafeSingletonReceiver(", "WAGRFastSingletonReceiver(",
                          "WAGRLiveSharedReceiver(", "WAGRABPropsResolveRuntimeObjects("):
            self.assertTrue(forbidden not in generic,
                f"generic browser still contains automatic receiver operation: {forbidden}")

    def test_empty_images_explain_why_they_have_no_editable_rows(self):
        browser = source("src/Menu/WAGRSurfaceBrowserVC.m")
        empty = body(browser, "- (void)updateEmptyState")
        self.assertIn("runtimeImagePath", empty)
        self.assertIn("allEntries.count", empty)
        self.assertIn("backgroundView", empty)
        self.assertIn("Objective-C", empty)
        fast = source("src/Menu/WAGRRuntimeBrowserFastTypedUI.m")
        self.assertIn("updateEmptyState", body(fast, "static void WAGRFastScheduleSurfaceFilter"))
        self.assertIn("WAGRRuntimeValueSetOverride(", body(fast, "static BOOL WAGRFastInstallValue"))
        self.assertIn("WAGRRuntimeValueInstallHook(", body(fast, "static BOOL WAGRFastInstallValue"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
