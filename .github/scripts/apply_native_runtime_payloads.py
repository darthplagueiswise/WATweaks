#!/usr/bin/env python3
from pathlib import Path
import base64
import gzip
import re

PAYLOADS = {
    '.watweaks-payload/NativeOverrideEngine.m.gz.b64': 'src/Runtime/WAGRABPropsNativeOverrideEngine.m',
    '.watweaks-payload/NativeOverrideEngine.h.gz.b64': 'src/Runtime/WAGRABPropsNativeOverrideEngine.h',
    '.watweaks-payload/MobileConfigNativeEngine.m.gz.b64': 'src/Runtime/WAGRMobileConfigNativeEngine.m',
    '.watweaks-payload/MobileConfigNativeEngine.h.gz.b64': 'src/Runtime/WAGRMobileConfigNativeEngine.h',
    '.watweaks-payload/ReleaseNativeLinkage.m.gz.b64': 'src/Runtime/WAGRABPropsReleaseNativeLinkage.m',
    '.watweaks-payload/MobileConfigExportVC.m.gz.b64': 'src/Menu/WAGRMobileConfigExportVC.m',
}

for src, dst in PAYLOADS.items():
    encoded = Path(src).read_text(encoding='utf-8').strip()
    Path(dst).write_bytes(gzip.decompress(base64.b64decode(encoded)))

editor_path = Path('src/Menu/WAGRABPropsNativeEditor.m')
editor = editor_path.read_text(encoding='utf-8')
editor_replacements = [
    (
        'Aplicado pelo MobileConfig nativo em memória.',
        'Aplicado pelo StartupConfigs nativo, persistido no App Group e confirmado pelo getter efetivo.',
    ),
    (
        'Aplicar usa FBMobileConfigStartupConfigs em memória e invalida o contexto MobileConfig. A persistência física em mc_overrides.json continua desativada até o serializer nativo ser comprovado; não instala swizzle WAAB.',
        'Aplicar usa FBMobileConfigStartupConfigs, confirma FBMobileConfigStartupConfigsOverride* no App Group, invalida o UserSession e relê o getter tipado efetivo. mc_overrides.json é uma tabela C++ separada e permanece read-only até seu serializer nativo ser provado; não instala swizzle WAAB.',
    ),
    ('Override nativo atual: nenhum', 'mc_overrides C++ atual (read-only): nenhum'),
    ('Override nativo atual: ', 'mc_overrides C++ atual (read-only): '),
]
for old, new in editor_replacements:
    if old not in editor:
        raise SystemExit(f'NativeEditor expected text missing: {old}')
    editor = editor.replace(old, new)
editor_path.write_text(editor, encoding='utf-8')

validator_path = Path('scripts/wagr_validate_abprops_fetch.py')
validator = validator_path.read_text(encoding='utf-8')
path_anchor = 'NATIVE_OVERRIDE = ROOT / "src/Runtime/WAGRABPropsNativeOverrideEngine.m"\n'
path_add = (
    'MC_NATIVE = ROOT / "src/Runtime/WAGRMobileConfigNativeEngine.m"\n'
    'RELEASE_LINKAGE = ROOT / "src/Runtime/WAGRABPropsReleaseNativeLinkage.m"\n'
    'MC_EXPORT = ROOT / "src/Menu/WAGRMobileConfigExportVC.m"\n'
)
if path_add not in validator:
    if path_anchor not in validator:
        raise SystemExit('validator path anchor missing')
    validator = validator.replace(path_anchor, path_anchor + path_add, 1)

read_anchor = '    native_override = read(NATIVE_OVERRIDE, errors)\n'
read_add = (
    '    mc_native = read(MC_NATIVE, errors)\n'
    '    release_linkage = read(RELEASE_LINKAGE, errors)\n'
    '    mc_export = read(MC_EXPORT, errors)\n'
)
if read_add not in validator:
    if read_anchor not in validator:
        raise SystemExit('validator read anchor missing')
    validator = validator.replace(read_anchor, read_anchor + read_add, 1)

new_checks = '''    # ABProps editing is a verified native StartupConfigs transaction. The
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
'''
pattern = re.compile(
    r'    # ABProps editing currently uses the proven native StartupConfigs memory\n.*?(?=    timeout_section = live\.split)',
    re.S,
)
validator, count = pattern.subn(new_checks + '\n', validator, count=1)
if count != 1:
    raise SystemExit(f'validator MobileConfig block replacement count={count}')
validator_path.write_text(validator, encoding='utf-8')

# Bootstrap artifacts are not part of the finished source tree.
for src in PAYLOADS:
    Path(src).unlink()
Path('.github/scripts/apply_native_runtime_payloads.py').unlink()
