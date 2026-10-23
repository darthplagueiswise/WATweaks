#!/usr/bin/env python3
"""Control semantics and focused UIKit integration guards; no device simulation."""
from pathlib import Path
import json
import re
import subprocess
import tempfile
import unittest
from wagr_validate_runtime_browser import body

ROOT = Path(__file__).resolve().parents[1]
def source(path):
    return (ROOT / path).read_text()

class ConfigControlTests(unittest.TestCase):
    maxDiff = 1000
    def test_false_override_native_reset_and_rejected_outcomes(self):
        self.assertTrue((ROOT / 'src/Runtime/WAGRConfigControlPolicy.h').is_file(),
                        'Missing three-state/mutation outcome policy')
        self.assertTrue((ROOT / 'src/Runtime/WAGRConfigControlCatalog.h').is_file(),
                        'Missing IPA-backed catalog consumed by control policy')
        with tempfile.TemporaryDirectory() as tmp:
            binary = str(Path(tmp) / 'controls')
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT / 'src/Runtime'),
                            str(ROOT / 'scripts/fixtures/config_control_policy_test.c'),
                            '-o', binary], check=True)
            subprocess.run([binary], check=True)

    def test_rejected_writes_cannot_be_presented_as_saved_pending(self):
        store = source('src/Runtime/WAGRRuntimeValueStore.m')
        self.assertIn('WAGRRuntimeValueTrySetOverride(', store)
        self.assertIn('WAGRConfigControlOutcome(', store)
        editor = source('src/Menu/WAGRRuntimeValueEditor.m')
        self.assertIn('WAGRRuntimeValueTrySetOverride(', editor)
        self.assertIn('WAGRRuntimeOverrideRejected', editor)
        browser = source('src/Menu/WAGRABPropsBrowserVC.m')
        self.assertIn('WAGRRuntimeValueTrySetOverride(', browser)
        self.assertIn('WAGRRuntimeOverrideRejected', browser)
        self.assertIn('WAGRRuntimeValueCanOverrideTarget(', browser)

    def test_three_state_controls_have_real_removal_and_conflict_checks(self):
        browser = source('src/Menu/WAGRABPropsBrowserVC.m')
        self.assertIn('wagrUsesThreeStateControls', browser)
        self.assertIn('threeStateChanged:', browser)
        self.assertIn('WAGRConfigControlMutationAllowed(', browser)
        self.assertIn('WAGRABPropsNativeClearOverride(', browser)
        self.assertIn('WAGRRuntimeValueClearOverride(', browser)
        self.assertIn('wagrIncludesRuntimeEntry:', browser)

    def test_explicit_nil_override_is_not_mistaken_for_a_rejected_write(self):
        self.assertTrue('value == NSNull.null ? nil : value' in source('src/Runtime/WAGRRuntimeValueStore.m'),
                        'Explicit nil must compare to the decoded nil, after checking stored override existence')

    def test_catalog_controls_belong_to_exact_ipa_families(self):
        path = ROOT / 'src/Runtime/WAGRConfigControlCatalog.h'
        self.assertTrue(path.is_file(), 'Missing IPA-backed control catalog')
        rows = re.findall(r'WAGR_CONTROL\("([^"]+)",\s*"([^"]+)",\s*"([^"]+)",\s*\w+,\s*"([^"]+)",\s*"([^"]+)"\)', path.read_text())
        catalog = json.loads(source('resources/waab_family_catalog_26_40_10.json'))['selectors']
        self.assertGreaterEqual(len(rows), 30)
        for selector, title, kind, image, category in rows:
            self.assertIn(category, catalog.get(selector, {}).get(image, []), selector)
            self.assertIn(kind, ['B', 'q', 'd'])

    def test_curated_panels_are_reachable_and_validate_current_build(self):
        path = ROOT / 'src/Menu/WAGRConfigControlsVC.m'
        self.assertTrue(path.is_file(), 'Missing curated control panel')
        panel = path.read_text()
        for token in ['WAGRConfigControlCatalogBuildMatches(', 'wagrIncludesRuntimeEntry:',
                      'wagrUsesThreeStateControls', 'wagrUsesNativeABPropertiesWriter',
                      'WAGRConfigControlFind(', 'backendChanged:']:
            self.assertTrue(token in panel, token)
        main = source('src/Menu/WAGRMainSettingsVC.m')
        self.assertTrue('WAGRConfigControlsVC' in main)
        families = source('src/Menu/WAGRFeatureBundlesVC.m')
        # Account/session object getters resolve on the main thread, before work dispatch.
        resolve = families.index('WAGRABPropsResolveRuntimeObjects(context)')
        worker = families.index('dispatch_async(dispatch_get_global_queue', families.index('- (void)scanLiveFamilies'))
        self.assertLess(resolve, worker)

    def test_mc_fetch_is_visible_serialized_and_scan_cannot_keep_stale_mappings(self):
        screen = source('src/Menu/WAGRMobileConfigExportVC.m')
        self.assertTrue('self.fetchButton' in screen, 'Native fetch must be a visible control')
        scan = body(screen, '- (void)scanNow')
        self.assertTrue('self.fetching' in scan, 'Scan must not start during native fetch')
        self.assertTrue('self.allMappings = @[]' in scan, 'Failed rescan must not retain mappings from an old scan')
        self.assertTrue('self.visibleMappings = @[]' in scan)
        fetch = body(screen, '- (void)fetchServerNow')
        self.assertTrue('self.fetching = YES' in fetch)
        self.assertTrue('self.fetching = NO' in fetch)

    def test_reset_clears_native_overrides_before_forgetting_managed_preferences(self):
        main = source('src/Menu/WAGRMainSettingsVC.m')
        self.assertTrue('WAGRABPropsNativeClearTrackedOverrides(' in main,
                        'Reset currently forgets registry while native overrides survive')
        reset = body(main, 'static NSDictionary *WAGRResetManagedConfiguration(')
        self.assertLess(reset.index('WAGRABPropsNativeClearTrackedOverrides('),
                        reset.index('removeObjectForKey:'))
        self.assertTrue('WAGRABPropsNativeTrackedOverrides().count' in reset)
        self.assertTrue('return @{ @"success": @NO' in reset)
        self.assertTrue('WAGRRuntimeValueClearOverride(' in reset)

    def test_native_editor_removes_startup_override_independently_of_cpp_file(self):
        editor = source('src/Menu/WAGRABPropsNativeEditor.m')
        self.assertTrue('WAGRABPropsNativeTrackedOverrides()[stableID]' in editor)
        self.assertFalse('if (nativeRow.length)' in editor,
                         'A separate read-only C++ file cannot determine StartupConfigs removability')
        self.assertTrue('WAGRRuntimeValueCanOverrideTarget(' in editor)

    def test_actual_build_excludes_legacy_browser_and_reset_replacements(self):
        makefile = source('Makefile')
        discovery = makefile[makefile.index('# ── Source discovery'):makefile.index('# SideStore-only')]
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'sources.mk'
            script.write_text('TWEAK_NAME = WATweaks\n' + discovery +
                              '\n$(info SOURCES=$(WATWEAKS_SRC_FILES))\nall:;\n')
            result = subprocess.run(['make', '-s', '-f', str(script)], cwd=ROOT,
                                    capture_output=True, text=True, check=True)
        files = result.stdout.split('SOURCES=', 1)[1].splitlines()[0].split()
        self.assertIn('src/Menu/WAGRABPropsBrowserVC.m', files)
        for retired in ['src/Menu/WAGRABPropsInlineTypedUI.m',
                        'src/Menu/WAGRABPropsBrowserPerformanceUI.m',
                        'src/Menu/WAGRABPropsExactTypedValueUI.m',
                        'src/Hooks/WAGRABPropsNativeEditorHook.xm',
                        'src/Menu/WAGRScopedResetUI.m',
                        'src/Menu/WAGRMobileConfigExportRuntimeUI.m']:
            self.assertNotIn(retired, files, retired + ' still replaces canonical UI at runtime')

    def test_remaining_installers_do_not_replace_canonical_abprops_methods(self):
        for file, signature in [
            ('src/Menu/WAGRRuntimeBrowserCompactUI.m', 'static void WAGRRuntimeBrowserNativeUICtor('),
            ('src/Menu/WAGRRuntimeBrowserFastTypedUI.m', 'static void WAGRFastInstall('),
            ('src/Menu/WAGRRuntimeObjectFullscreenEditor.m', 'static void WAGRInstallFullRuntimeEditors(')]:
            self.assertTrue('NSClassFromString(@"WAGRABPropsBrowserVC")' not in body(source(file), signature), file)
        glass = source('src/Menu/WAGRRuntimeBrowsersGlassUI.m')
        self.assertTrue('WAGRBrowserInstallForClass(@"WAGRABPropsBrowserVC", YES, NO)' in glass)

    def test_canonical_filter_keeps_search_off_main_and_rejects_stale_results(self):
        screen = source('src/Menu/WAGRABPropsBrowserVC.m')
        filter_body = body(screen, '- (void)applyCurrentFilter')
        for token in ['dispatch_async(self.filterQueue', 'filterGeneration', 'nativeIndex',
                      'wagrIncludesRuntimeEntry:', 'wagrABPropertiesTitleForEntryCount:']:
            self.assertTrue(token in filter_body, token)
        self.assertNotIn('[self nativeEntryForRuntimeEntry:', filter_body)

    def test_scoped_reset_native_guard_runs_before_local_deletion(self):
        screen = source('src/Menu/WAGRScopedReset.m')
        confirm = body(screen, 'static void WAGRResetConfirm(')
        self.assertTrue('WAGRABPropsNativeClearTrackedOverrides(' in confirm)
        self.assertLess(confirm.index('WAGRABPropsNativeClearTrackedOverrides('), confirm.index('WAGRResetPerform('))

    def test_full_object_editor_is_invoked_after_policy_and_reports_real_outcome(self):
        browser = source('src/Menu/WAGRABPropsBrowserVC.m')
        editor = body(browser, '- (void)presentEditorForEntry:')
        self.assertTrue('WAGRPresentRuntimeFullObjectEditor(' in editor)
        self.assertLess(editor.index('canChangeEntry:'), editor.index('WAGRPresentRuntimeFullObjectEditor('))
        full = source('src/Menu/WAGRRuntimeObjectFullscreenEditor.m')
        apply = full.split('- (void)applyPressed {', 1)[1].split('\n- (void)showError:', 1)[0]
        self.assertTrue('WAGRRuntimeValueTrySetOverride(' in apply)
        self.assertTrue('WAGRRuntimeOverrideRejected' in apply)

    def test_active_generic_inline_handler_cannot_mark_rejection_pending(self):
        fast = source('src/Menu/WAGRRuntimeBrowserFastTypedUI.m')
        install = body(fast, 'static BOOL WAGRFastInstallValue(')
        self.assertTrue('WAGRRuntimeValueTrySetOverride(' in install)
        self.assertTrue('outcome == WAGRRuntimeOverridePending' in install)
        self.assertTrue('WAGRRuntimeValueCanOverrideTarget(' in body(fast, 'static UITableViewCell *WAGRFastSurfaceCell('))

if __name__ == '__main__':
    unittest.main()
