#!/usr/bin/env python3
"""Portable regression for native MobileConfig ABI routing and account correlation."""
import pathlib
import subprocess
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
class MobileConfigFetchTests(unittest.TestCase):
    def test_native_abi_and_account_policy(self):
        header = ROOT / 'src/Runtime/WAGRMobileConfigFetchPolicy.h'
        self.assertTrue(header.is_file(), 'Missing 26.40 native fetch routing/account policy')
        with tempfile.TemporaryDirectory() as tmp:
            binary = pathlib.Path(tmp) / 'mc-policy'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'src/Runtime'), str(ROOT / 'scripts/fixtures/mobileconfig_fetch_policy_test.c'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
    def test_runtime_calls_selected_abi_and_requires_captured_account(self):
        source = (ROOT / 'src/Runtime/WAGRMobileConfigNativeEngine.m').read_text()
        for token in ['WAGRMCFetchSelectRoute(', 'WAGRMCFetchMarkerMatches(', 'WAGRMCFetchNativeStackAutomatic', 'gWAGRMCFetchExpectedPreferencesStore', 'gWAGRMCFetchContext']:
            self.assertTrue(token in source, 'Missing production binding: ' + token)
    def test_refresh_does_not_tear_down_live_manager(self):
        source = (ROOT / 'src/Runtime/WAGRMobileConfigNativeEngine.m').read_text()
        refresh = source.split('BOOL WAGRMobileConfigNativeInvalidate(', 1)[1].split('BOOL WAGRMobileConfigNativeWriteOverrideDocument(', 1)[0]
        self.assertTrue('WAGRMCNativeInvokeVoidNoArg(manager, @"invalidateCachedLatestContext")' in refresh)
        self.assertFalse('WAGRMCNativeInvokeVoidNoArg(manager, @"forceInvalidate")' in refresh, 'Native forceInvalidate clears the C++ manager/listeners; it is dealloc teardown')
    def test_account_binding_cannot_use_other_context_global_capture(self):
        source = (ROOT / 'src/Runtime/WAGRMobileConfigNativeEngine.m').read_text()
        fetch = source.split('BOOL WAGRMobileConfigNativeFetchAccount(', 1)[1].split('NSDictionary<NSString *, id> *WAGRMobileConfigNativeFetchState(', 1)[0]
        self.assertFalse('WAGRMobileConfigUserSessionContextManager(' in fetch, 'Context A must not dispatch with globally captured manager B')
        self.assertTrue('WAGRMCNativeBoundAccountManager(context)' in fetch, 'Account dispatch must resolve its own properties.mc route')
        self.assertTrue('gWAGRMCFetchManager = manager;' in fetch, 'Keep the bound native manager for this transaction')
        self.assertTrue('WAGRMCNativeLatestConfigPathForManager(manager)' in fetch, 'The timeout must use the captured manager')
        self.assertTrue('static id WAGRMCNativeBoundAccountManager(' in source)
        binding = source.split('static id WAGRMCNativeBoundAccountManager(', 1)[1].split('static NSString *WAGRMCNativeLatestConfigPathForManager(', 1)[0]
        self.assertTrue('WAGRMCNativeCallObjectNoArg(context, @"abProperties")' in binding)
        self.assertTrue('WAGRMCNativeCallObjectNoArg(properties, @"mc")' in binding)
        self.assertTrue('isKindOfClass:expected' in binding)
        self.assertFalse('WAGRMobileConfigUserSessionContextManager(' in binding)
        marker = source.split('static void WAGRMCNativeFetchSuccessMarker(', 1)[1].split('static BOOL WAGRMCNativeInstallFetchSuccessMarkerObserver(', 1)[0]
        self.assertTrue('manager = gWAGRMCFetchManager;' in marker)
        self.assertTrue('WAGRMCNativeLatestConfigPathForManager(manager)' in marker)
if __name__ == '__main__':
    unittest.main()
