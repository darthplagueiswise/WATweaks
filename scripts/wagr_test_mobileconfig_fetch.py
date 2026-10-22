#!/usr/bin/env python3
"""Portable regression for native MobileConfig ABI routing and account correlation."""
import pathlib
import os
import subprocess
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
class MobileConfigFetchTests(unittest.TestCase):
    def test_native_specifier_span_bounds_and_current_domain(self):
        header = ROOT / 'src/Runtime/WAGRMobileConfigSpecifierSpan.h'
        self.assertTrue(header.is_file(), 'Missing native pointer/count span reader; removed selector still required')
        with tempfile.TemporaryDirectory() as tmp:
            binary = pathlib.Path(tmp) / 'mc-span'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I', str(ROOT / 'src/Runtime'), str(ROOT / 'scripts/fixtures/mobileconfig_specifier_span_test.c'), '-o', str(binary)], check=True)
            # This fixture owns no heap allocations; LeakSanitizer cannot inspect
            # /proc under some sandbox/ptrace hosts. Keep ASan/UBSan enabled.
            subprocess.run([str(binary)], check=True,
                           env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})

    def test_all_specifier_consumers_share_the_current_native_mapper(self):
        for path in ['Runtime/WAGRMobileConfigBridge.m',
                     'Runtime/WAGRABPropsNativeOverrideEngine.m',
                     'Runtime/WAGRABPropsNativeStore.m',
                     'Runtime/WAGRABPropsCanonicalNamesV2.m',
                     'Menu/WAGRABPropsLiveCorrelation.m']:
            source = (ROOT / 'src' / path).read_text()
            self.assertNotIn('getMCSpecifierForStableId:', source, path)
            self.assertIn('WAGRMobileConfigSpecifierForWAStableID(', source, path)
        bridge = (ROOT / 'src/Runtime/WAGRMobileConfigBridge.m').read_text()
        self.assertNotIn('34666', bridge)
        self.assertIn('getWAStableIdToParamSpecifierEntries', bridge)
        self.assertIn('vm_read_overwrite(', bridge)
        self.assertNotIn('mach_vm_read_overwrite(', bridge)
        self.assertNotIn('<mach/mach_vm.h>', bridge)

    def test_native_account_state_and_names_are_bound_to_the_fetch(self):
        source = (ROOT / 'src/Runtime/WAGRMobileConfigNativeEngine.m').read_text()
        self.assertIn('WAGRNativeAccountStateDocument(context)', source)
        self.assertIn('@"account_state_before"', source)
        self.assertIn('@"artifacts_before"', source)
        self.assertIn('@"artifacts_after"', source)
        self.assertIn('@"id_name_mapping"', source)
        self.assertIn('@"qe_info"', source)
        self.assertIn('WAGRMCNativeArtifactsForManager(manager)', source)
        self.assertIn('WAGRMCNativeCallObjectNoArg(manager, @"getOverridesTablePath")', source)
        self.assertNotIn('if (!WAGRNativeAccountStateDocument', source)
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

    def test_missing_diagnostic_observers_do_not_block_native_dispatch(self):
        """Regression: deleting either observer must not suppress WAChatManager fetch."""
        source = (ROOT / 'src/Runtime/WAGRMobileConfigNativeEngine.m').read_text()
        fetch = source.split('BOOL WAGRMobileConfigNativeFetchAccount(', 1)[1].split(
            'NSDictionary<NSString *, id> *WAGRMobileConfigNativeFetchState(', 1)[0]
        dispatch = fetch.index('objc_msgSend)(chatManager, selector')
        prefix = fetch[:dispatch]
        self.assertIn('BOOL xwa2ObserverInstalled = WAGRMCNativeInstallXWA2SuccessObserver();', prefix)
        self.assertIn('BOOL markerObserverInstalled = WAGRMCNativeInstallFetchSuccessMarkerObserver();', prefix)
        self.assertNotIn('if (!WAGRMCNativeInstallXWA2SuccessObserver())', prefix)
        self.assertNotIn('if (!WAGRMCNativeInstallFetchSuccessMarkerObserver())', prefix)
        self.assertIn('@"xwa2_success_observer_installed" : @(xwa2ObserverInstalled)', fetch)
        self.assertIn('@"success_marker_observer_installed" : @(markerObserverInstalled)', fetch)

    def test_native_route_and_query_protocol_are_reported_without_synthesizing_input(self):
        linkage = (ROOT / 'src/Runtime/WAGRABPropsReleaseNativeLinkage.m').read_text()
        engine = (ROOT / 'src/Runtime/WAGRMobileConfigNativeEngine.m').read_text()
        for token in ['snapshot[@"route"] = @"xwa2"', '@"www_authenticated"',
                      '@"www_sessionless"',
                      '@"canonical_user_credentials:mobile_config"',
                      '@"WAGraphQLStaticAuthTokens.staticAT"',
                      '@"global_value_hash"', '@"ep_refresh_id"', '@"query_string"',
                      '@"bln_li_hashes"', '@"bln_queries"', '@"bool_opt_policy"']:
            self.assertIn(token, linkage)
        self.assertIn('@"native_entrypoint_dispatched_waiting_fetch_plan_or_network"', engine)
        self.assertIn('@"timeout_after_www_request"', engine)
        self.assertIn('@"timeout_after_xwa2_request"', engine)
        self.assertIn('@"timeout_before_network_observed"', engine)
        for token in ['UnknownOneQueryHash', 'OneQueryHashError', 'BlnQueriesError',
                      'native retries with one_query_string']:
            self.assertIn(token, engine)
        self.assertNotIn('setQueryString:', linkage)
        self.assertNotIn('setGlobalValueHash:', linkage)
if __name__ == '__main__':
    unittest.main()
