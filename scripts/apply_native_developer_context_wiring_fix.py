#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "src/Hooks/WAGRNativeDevMenuHooks.xm"
VALIDATOR = ROOT / "scripts/wagr_validate_abprops_fetch.py"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {n}")
    return text.replace(old, new, 1)


def patch_hook() -> None:
    text = HOOK.read_text(encoding="utf-8")
    if 'extern "C" void WAGRContextSpyInstallForContext(id ctx);' not in text:
        text = replace_once(
            text,
            'extern "C" void WAGRContextSpyInstallForObject(id obj);\n',
            'extern "C" void WAGRContextSpyInstallForObject(id obj);\nextern "C" void WAGRContextSpyInstallForContext(id ctx);\n',
            'context-spy forward declaration')

    replacements = (
        ('WAGRContextSpyInstallForObject(userContext);', 'WAGRContextSpyInstallForContext(userContext);'),
        ('WAGRContextSpyInstallForObject(context);', 'WAGRContextSpyInstallForContext(context);'),
        ('WAGRContextSpyInstallForObject(realCtx);', 'WAGRContextSpyInstallForContext(realCtx);'),
    )
    for old, new in replacements:
        if old in text:
            text = replace_once(text, old, new, old)
        elif new not in text:
            raise SystemExit(f"neither old nor new context call found: {old}")

    # Preserve ForObject for dependency objects such as accountProvider only.
    for forbidden in (
        'WAGRContextSpyInstallForObject(userContext);',
        'WAGRContextSpyInstallForObject(context);',
        'WAGRContextSpyInstallForObject(realCtx);',
    ):
        if forbidden in text:
            raise SystemExit(f"wrong context helper remains: {forbidden}")
    for required in (
        'WAGRContextSpyInstallForContext(userContext);',
        'WAGRContextSpyInstallForContext(context);',
        'WAGRContextSpyInstallForContext(realCtx);',
        'WAGRContextSpyInstallForObject(provider);',
        '@"debugPropOverrides"',
        '@"privateABProperties"',
    ):
        if required not in text:
            raise SystemExit(f"context wiring invariant missing: {required}")
    HOOK.write_text(text, encoding="utf-8")


def patch_validator() -> None:
    text = VALIDATOR.read_text(encoding="utf-8")
    anchor = '        "WAContextObjectProvider",\n'
    if '"WAGRContextSpyInstallForContext",' not in text:
        if anchor not in text:
            raise SystemExit('Developer validator anchor missing')
        text = text.replace(anchor, anchor + '        "WAGRContextSpyInstallForContext",\n', 1)

    reject_anchor = '        "Current WhatsApp(10)",\n'
    if '"WAGRContextSpyInstallForObject(userContext);",' not in text:
        if reject_anchor not in text:
            raise SystemExit('Developer reject validator anchor missing')
        additions = (
            '        "WAGRContextSpyInstallForObject(userContext);",\n'
            '        "WAGRContextSpyInstallForObject(context);",\n'
            '        "WAGRContextSpyInstallForObject(realCtx);",\n'
        )
        text = text.replace(reject_anchor, reject_anchor + additions, 1)
    VALIDATOR.write_text(text, encoding="utf-8")


patch_hook()
patch_validator()
print('native Developer account-context wiring fixed')
