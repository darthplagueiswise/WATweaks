# WATweaks cleanup pass 2

This pass focuses on the issues reported after the first fixed zip.

## Menus

- Kept `WAGRSurfaceListVC` as the single root menu.
- Removed the old duplicate root-owner path in the prior pass and kept all entry points routing to `WAGRSurfaceListVC`.
- Kept advanced/runtime screens only as child screens under the one root menu:
  - native Developer menu launcher
  - secret/internal bundles
  - runtime gates by category
  - raw runtime browser for debugging only
  - diagnostics/logs/system reset

## Hooks

- Added `src/Hooks/WAGRBootstrap.xm` as the only constructor in the main tweak target.
- Disabled per-hook constructors in the main hook files.
- Bootstrap now coordinates:
  - settings button hooks
  - native Developer menu hooks
  - debug menu instrumentation
  - WAAB/gate runtime owner
  - dogfood/internal hooks
  - context hooks
  - account eligibility hooks
  - Aura hooks/navigation
  - Liquid Glass hooks
  - persisted runtime hooks
  - optional keychain hooks
- Kept only one late centralized retry pass instead of multiple per-file retry storms.

## Persistence / NSUserDefaults

- `WAGRGateStore` is now the canonical persistence owner for tweak UI/runtime prefs.
- `WAEnabled`, `WASetEnabled`, `WAGRPref`, and `WAGRIsOn` resolve through `WAGRGateStore`.
- Legacy aliases are migrated/normalized into the `watweak_*` namespace.
- Direct writes for master toggles, Aura simulation, Settings force-payments, and account-eligibility overrides were replaced with gate-store calls.
- Old aliases retained only for migration/cleanup:
  - `wagr.*`
  - `wa_lg_*`
  - old `wa_*` pref constants
  - old `watweak_bundle_*`

## Prefix

Canonical persisted keys now use:
- `watweak_ui_*` for tweak UI/master preferences
- `watweak_gate_*` for runtime/WAAB gate overrides

Remaining `NSUserDefaults` usage outside `WAGRGateStore` is limited to:
- default registration
- backup/reset inspection
- native WhatsApp Liquid Glass compatibility keys where WhatsApp itself expects those names
- diagnostics/read-only scans

## Build note

This environment does not include the iOS/Theos toolchain, so the package was statically inspected and rewritten but not compiled here.
