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

    # Full fetch must be the active native hash-reset pair, never a process-wide
    # interception of XMPPRequestABProperties.
    for token in (
        "resetConfigHashToEmptyString",
        "requestFreshABProps:withCompletion:",
        "validator_reset_confirmed",
        "config_hash_refilled",
        "verified_native_completion_hash_refilled",
        "hook_installed\": @NO",
        "gate_quarantined_until_native_completion",
    ):
        require(force, token, "WAGRABPropsABTForceFull.m", errors)
    for token in (
        "method_setImplementation",
        "MSHookMessageEx",
        "MSHookFunction",
        "ForceFullRequestInitHook",
        "initWithUserContext:groupJID:configHash:refreshID:completion:",
        "__attribute__((constructor))",
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
        require(force, token, "WAGRABPropsABTForceFull.m", errors)
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

    # ABProps editing currently uses the proven native StartupConfigs memory
    # path. Until the main serializer is recovered, the UI must never claim
    # that this path persisted the physical App Group override document.
    for token in (
        "FBMobileConfigStartupConfigs em memória",
        "persistência física em mc_overrides.json continua desativada",
    ):
        require(native_editor, token, "WAGRABPropsNativeEditor.m", errors)
    reject(native_editor, "Aplicar grava no mc_overrides.json",
           "WAGRABPropsNativeEditor.m", errors)
    for token in (
        "setOverrideForParam:andValue:",
        "removeOverrideForParam:",
        "diskWriter=disabled-until-main-serializer-proven",
        "physical mc_overrides untouched by design",
    ):
        require(native_override, token, "WAGRABPropsNativeOverrideEngine.m", errors)

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
