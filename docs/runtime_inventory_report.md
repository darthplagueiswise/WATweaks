# Runtime inventory pass: WAAB / WAContext / WAAura / WAFoa / WABiz / WAServerProperties

This pass adds the inventory layer that should exist before a final Import/Export system.

Generated files:

- `resources/runtime/WAABProperties.json`
- `resources/runtime/WAContext.json`
- `resources/runtime/WAAura.json`
- `resources/runtime/WAMobileConfig.json`
- `resources/runtime/WAFoa.json`
- `resources/runtime/WABiz.json`
- `resources/runtime/WAServerProperties.json`
- `resources/runtime/manifest.json`

Methodology:

- `scripts/generate_runtime_inventory.py` parses the uploaded `SharedModules` and main `WhatsApp` Mach-O binaries with LIEF.
- The same script imports Capstone and disassembles a small ARM64 text probe for each binary, recording it under `binaries.*.text_probe` so the output records that the binary slice was readable as ARM64 code.
- The inventories are grouping/mapping data only. They are not runtime force-return patches, subscription bypasses, or entitlement injectors.

Important grouping decisions:

- `WAContextMain` is nested under the `WAContext` family as `ContextMain Runtime`. It should not become a separate top-level menu.
- `WAAura` is split into `WAAuraGating`, `WAAuraFoundation`, provider/preferences surfaces, and executable controllers such as `WAAura.AppThemesViewController` and `WAAura.AppIconsViewController`.
- `WAFoaAppUtilities` is its own FOA family for Instagram/Facebook/Threads/Meta AI presence and cross-app routing.
- `WABiz` has its own tree and is explicitly marked as consuming `WAABProperties` through `abProperties`/business storage/cache surfaces.
- `WAServerProperties` is recorded as the central server/internal gate bridge into `userContext -> WAContext -> WAContextMain`.

Build/staging note:

The `Makefile` now stages `resources/runtime/*.json` into:

`/Library/Application Support/WATweaks/runtime/`

This keeps the inventory data available at runtime without changing hook behavior.
