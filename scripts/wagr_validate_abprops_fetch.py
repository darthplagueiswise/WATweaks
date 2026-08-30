#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORCE = ROOT / "src/Runtime/WAGRABPropsABTForceFull.m"
BROWSER = ROOT / "src/Menu/WAGRABPropsBrowserVC.m"
SNAPSHOT = ROOT / "src/Menu/WAGRABPropsSnapshotVC.m"
DEBUG = ROOT / "src/Menu/WAGRDebugDiagnosticsVC.m"
LIVE = ROOT / "src/Runtime/WAGRABPropsABTLiveService.m"
LAB = ROOT / "src/Runtime/WAGRABPropsABTLab.m"
LAB_UI = ROOT / "src/Menu/WAGRABPropsABTLabVC.m"
ROOT_UI = ROOT / "src/Menu/WAGRABPropsRootVC.m"
GATE = ROOT / "src/Runtime/WAGRABPropsABTTransactionGate.m"
BRIDGE = ROOT / "src/Runtime/WAGRABPropsABTNativeBridge.m"
NATIVE = ROOT / "src/Runtime/WAGRABPropsNativeStore.m"
NATIVE_EDITOR = ROOT / "src/Menu/WAGRABPropsNativeEditor.m"
NATIVE_OVERRIDE = ROOT / "src/Runtime/WAGRABPropsNativeOverrideEngine.m"
MC_NATIVE = ROOT / "src/Runtime/WAGRMobileConfigNativeEngine.m"
RELEASE_LINKAGE = ROOT / "src/Runtime/WAGRABPropsReleaseNativeLinkage.m"
MC_EXPORT = ROOT / "src/Menu/WAGRMobileConfigExportVC.m"
DEV_MENU = ROOT / "src/Hooks/WAGRNativeDevMenuHooks.xm"


def read(path: pathlib.Path, errors: list[str]) -> str:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return ""
    return path.read_text(encoding="utf-8", errors="ignore")


def require(text: str, token: str, label: str, errors: list[str]) -> None:
    if token not in text:
        errors.append(f"{label}: missing {token}")


def reject(text: str, token: str, label: str, errors: list[str]) -> None:
    if token in text:
        errors.append(f"{label}: forbidden {token}")


def main() -> int:
    errors: list[str] = []
    force = read(FORCE, errors)
    browser = read(BROWSER, errors)
    snapshot = read(SNAPSHOT, errors)
    debug = read(DEBUG, errors)
    live = read(LIVE, errors)
    lab = read(LAB, errors)
    lab_ui = read(LAB_UI, errors)
    root_ui = read(ROOT_UI, errors)
    gate = read(GATE, errors)
    bridge = read(BRIDGE, errors)
    native = read(NATIVE, errors)
    native_editor = read(NATIVE_EDITOR, errors)
    native_override = read(NATIVE_OVERRIDE, errors)
    mc_native = read(MC_NATIVE, errors)
    release_linkage = read(RELEASE_LINKAGE, errors)
    mc_export = read(MC_EXPORT, errors)
    dev_menu = read(DEV_MENU, errors)

    # The legacy force-full symbol is a compatibility adapter only. It must use
    # the same correlated full_empty_hash service as browser and Lab and may not
    # own a second gate, timeout or request implementation.
    for token in (
        "WAGRABPropsABTLiveFetchVariant",
        "WAGRABPropsABTVariantFullEmptyHash",
        "WAGRABPropsABTVerifiedFullEmptyHashResult",
        "watweaks_abprops_abt_force_full_adapter_v3",
        "delegates_to",
        "hook_installed\": @NO",
    ):
        require(force, token, "WAGRABPropsABTForceFull.m", errors)
    for token in (
        "method_setImplementation",
        "MSHookMessageEx",
        "MSHookFunction",
        "ForceFullRequestInitHook",
        "initWithUserContext:groupJID:configHash:refreshID:completion:",
        "__attribute__((constructor))",
        "WAGRABPropsABTTransactionAcquire",
        "WAGRABPropsABTTransactionRelease",
        "resetConfigHashToEmptyString",
        "requestFreshABProps:withCompletion:",
        "dispatch_after",
    ):
        reject(force, token, "WAGRABPropsABTForceFull.m", errors)

    # The concrete controllers own the action. Late UI IMP races must not return.
    for controller, label in (
        (browser, "WAGRABPropsBrowserVC.m"),
        (snapshot, "WAGRABPropsSnapshotVC.m"),
    ):
        for token in (
            "WAGRABPropsABTLiveFetchVariant",
            "WAGRABPropsABTVariantFullEmptyHash",
            "WAGRABPropsABTVerifiedFullEmptyHashResult",
            "WAGRABPropsABTAccountSnapshotDocument",
        ):
            require(controller, token, label, errors)
        for token in (
            "WAGRABPropsABTLiveFetchForcedFull",
            "WAGRABPropsReadNativeSnapshot(",
            "WAGRABPropsNativeExportDocument",
            'native[@"mobileconfig"]',
        ):
            reject(controller, token, label, errors)
    require(debug, "WAGRABPropsABTLiveFetchForcedFull", "WAGRDebugDiagnosticsVC.m", errors)
    reject(snapshot, "WAGRABPropsTriggerNativeFetch", "WAGRABPropsSnapshotVC.m", errors)
    reject(snapshot, "sleepForTimeInterval", "WAGRABPropsSnapshotVC.m", errors)
    for name in (
        "WAGRABPropsABTForceFullUI.m",
        "WAGRABPropsABTLiveServiceUI.m",
        "WAGRABPropsABTNativeBridgeUI.m",
    ):
        if ROOT.joinpath("src/Menu", name).exists():
            errors.append(f"late UI override still present: src/Menu/{name}")

    # The older correlated observers remain callable for explicit diagnostics,
    # but they must not install global hooks merely because WhatsApp launched.
    reject(live, "__attribute__((constructor))", "WAGRABPropsABTLiveService.m", errors)
    reject(bridge, "__attribute__((constructor))", "WAGRABPropsABTNativeBridge.m", errors)

    # The on-demand lab covers every supported validator shape and correlates
    # every retry with the exact request object; no hook may install at launch.
    for token in (
        "WAGRABPropsABTVariantRegularHash",
        "WAGRABPropsABTVariantDeltaRefreshID",
        "WAGRABPropsABTVariantFullEmptyHash",
        "WAGRABPropsABTVariantFullNoValidators",
        "WAGRABPropsABTVariantCustomWire",
        "WAGRABPropsABTLiveFetchCustom",
        "RequestInitHook",
        "DidFailHook",
        "gPendingRequests",
        "gActiveCallbackRequest",
        "gHandlerInFlightToken",
        "Finish(NSString *expectedToken)",
        "FinishWhenHandlerSettled",
        "wire_shape_matches_variant",
        "wire_attempts",
        "handler_attempts",
        "encrypted_rid_persistence_expected",
        "exact_account_wa_properties_store_not_resolved",
        "exact_native_wa_properties_store",
        "WAGRABPropsReadNativeSnapshotForProperties",
        "WAGRABPropsNativeABTOnlyExportDocument",
        "WAGRABPropsABTVerifiedFullEmptyHashResult",
        "verified_native_response_applied",
        "timeoutSeconds * NSEC_PER_SEC",
        "gTimeoutReported",
        "transaction_remains_correlated",
        "gate_released_at_timeout",
    ):
        require(live, token, "WAGRABPropsABTLiveService.m", errors)
    for token in (
        "WAGRABPropsABTLabMatrixVariants",
        "WAGRABPropsABTLabRunMatrix",
        "persistent_history",
        "session_results_compact",
        "last_matrix_results_compact",
        "WAGRABPropsABTVariantFullNoValidators",
        "WAGRABPropsABTVariantFullEmptyHash",
        "WAGRABPropsABTLabRunCustom",
        "matrix_aborted_after_timeout",
        "last_matrix_outcome",
        "WAGRABPropsABTTransactionReleaseWhenIdle",
        "live_service_state",
    ):
        require(lab, token, "WAGRABPropsABTLab.m", errors)
    for token in (
        "ABT Runtime Lab",
        "Rodar matriz completa",
        "Compartilhar JSON completo",
        "VERIFICADO exige request exato",
        "MobileConfig",
        "Wire custom em runtime",
        "Executar wire custom",
    ):
        require(lab_ui, token, "WAGRABPropsABTLabVC.m", errors)
    require(root_ui, "WAGRABPropsActionABTRuntimeLab", "WAGRABPropsRootVC.m", errors)
    reject(lab, "__attribute__((constructor))", "WAGRABPropsABTLab.m", errors)
    reject(live, "Finish();", "WAGRABPropsABTLiveService.m", errors)
    for token in (
        "WAGRABPropsABTTransactionAcquire",
        "WAGRABPropsABTTransactionRelease",
    ):
        require(gate, token, "WAGRABPropsABTTransactionGate.m", errors)
        require(live, token, "WAGRABPropsABTLiveService.m", errors)
    for token in ("WAGRABPropsABTTransactionReleaseWhenIdle", "owner_release_when_idle"):
        require(gate, token, "WAGRABPropsABTTransactionGate.m", errors)

    for token in (
        'class_getInstanceVariable([properties class], "_propertiesStore")',
        'ivar_getOffset(ownerIvar) != 8',
        'ivar_getOffset(preferencesIvar) != 8',
        'ivar_getOffset(namespaceIvar) != 32',
        'ivar_getOffset(typeIvar) != 48',
        'ivar_getOffset(groupIvar) != 56',
        'ivar_getOffset(propsIvar) != 96',
        "exact_native_wa_properties_store",
        "WAGRABPropsNativeABTOnlyExportDocument",
        "<stripped-empty; initializer ABI q48>",
        "@68@0:8@16@24@32@40q48@56B64",
    ):
        require(native, token, "WAGRABPropsNativeStore.m", errors)

    # ABProps editing is a verified native StartupConfigs transaction. The
    # StartupConfigs override is persisted in the native App Group defaults,
    # while physical mc_overrides.json remains a separate C++ table.
    for token in (
        "FBMobileConfigStartupConfigsOverride",
        "getter efetivo",
        "mc_overrides.json",
    ):
        require(native_editor, token, "WAGRABPropsNativeEditor.m", errors)
    for token in (
        "MobileConfig nativo em memória",
        "Aplicar grava no mc_overrides.json",
    ):
        reject(native_editor, token, "WAGRABPropsNativeEditor.m", errors)

    for token in (
        "setOverrideForParam:andValue:",
        "WAGRABNativeMethodReturnsBool",
        "sharedUserDefaultsForTesting",
        "FBMobileConfigStartupConfigsOverride",
        "WAGRMobileConfigCurrentValue",
        "Override reverted",
        "mc_overrides.json untouched",
        "WAGRABPropsNativeStartupOverrideStoreDocument",
        "WAGRABPropsNativeMCOverridesExportDocument",
        "This is not a server fetch",
    ):
        require(native_override, token, "WAGRABPropsNativeOverrideEngine.m", errors)

    for token in (
        "compatibility JSON writer BLOCKED",
        "WATweaks refuses direct JSON writes",
        "fetchMobileConfig:",
        "WAChatManager fetchMobileConfig:NO",
        "handleFetchSuccessResponse:error:fetchType:attemptIndex:maxAttempts:attemptCompletion:",
        "v64@0:8@16@24@32q40q48@?56",
        "setLastSuccessFetchInPreferencesStore:unitType:unitId:appVersion:",
        "v44@0:8@16i24@28@36",
        "preferenceKeyForLastSuccessFetch:unitId:",
        "preferenceKeyForLastSuccessFetchAppVersion:unitId:",
        "persistent_success_marker_verified",
        "verified_native_persisted_success_marker",
        "verified_server_response",
    ):
        require(mc_native, token, "WAGRMobileConfigNativeEngine.m", errors)
    reject(mc_native, "writeToFile:", "WAGRMobileConfigNativeEngine.m", errors)

    for token in (
        "WAGRABPropsNativeSetOverride",
        "WAGRABPropsNativeClearOverride",
        "xwa2_native_fetch_observed",
        "www_native_fetch_observed",
        "globalValueHash",
        "unitId",
    ):
        require(release_linkage, token, "WAGRABPropsReleaseNativeLinkage.m", errors)
    for token in (
        "WAGRLinkageStartupSet(",
        "WAGRLinkageRefreshConfig(",
    ):
        reject(release_linkage, token, "WAGRABPropsReleaseNativeLinkage.m", errors)

    for token in (
        "Fetch from server · native",
        "Export native id_name_mapping.json",
        "Export native mc_overrides.json · read-only",
        "Export native StartupConfigsOverride",
        "Export custom mc_overrides · verified ABProps only",
    ):
        require(mc_export, token, "WAGRMobileConfigExportVC.m", errors)
    reject(mc_export, "Aplicar no mc_overrides.json", "WAGRMobileConfigExportVC.m", errors)

    # WhatsApp 26.33 RC compiles the yellow AB Props placeholder directly
    # into WADebugViewController.createSections. The tweak must replace only
    # that placeholder with a native WATableRow that pushes WhatsApp's own
    # PrivateExperimentationDebugViewController using the account userContext.
    for token in (
        "watweaks_native_developer_abprops_wiring_v26_33",
        "hookDebugVCCreateSections",
        "createSections",
        "v16@0:8",
        "Private Experimentation Debug",
        "privateABProperties",
        "addTableRowWithCellStyle:",
        "setRows:",
        "setFooterText:",
        "_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController",
        'class_getInstanceVariable(cls, "experimentManager")',
        'class_getInstanceVariable(cls, "userContext")',
        "WAContextObjectProvider",
    ):
        require(dev_menu, token, "WAGRNativeDevMenuHooks.xm", errors)
    for token in (
        "WAGRReadMainPointerAtVM",
        "WAGRPrivateExpKickManagerIfAvailable",
        "0x107d2f938",
        "0x107d2f940",
        "orig_privateExpViewDidAppear",
        "Current WhatsApp(10)",
    ):
        reject(dev_menu, token, "WAGRNativeDevMenuHooks.xm", errors)

    timeout_section = live.split("explicit_transaction_timeout", 1)
    if len(timeout_section) != 2:
        errors.append("WAGRABPropsABTLiveService.m: timeout section not found")
    else:
        timeout_body = timeout_section[1].split("return YES;", 1)[0]
        require(timeout_body, "WAGRABPropsABTTransactionRelease(token)",
                "WAGRABPropsABTLiveService.m terminal timeout", errors)
        require(timeout_body, "gPending = NO",
                "WAGRABPropsABTLiveService.m terminal timeout", errors)
        require(timeout_body, 'mutable[@"gate_released_at_timeout"] = @YES',
                "WAGRABPropsABTLiveService.m terminal timeout", errors)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("ABProps validation: native full fetch, runtime matrix and transaction isolation verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
