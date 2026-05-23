# Runtime Browser Inventory Integration

This patch connects `resources/runtime/*.json` to the in-app Runtime Browser.

## Runtime entry point

Open WATweaks and use the new section:

`Runtime Browser por Inventário`

Rows are generated from:

- `resources/runtime/WAABProperties.json`
- `resources/runtime/WAServerProperties.json`
- `resources/runtime/WAContext.json`
- `resources/runtime/WAAura.json`
- `resources/runtime/WAMobileConfig.json`
- `resources/runtime/WAFoa.json`
- `resources/runtime/WABiz.json`

## Behavior

`WAGRRuntimeInventory` searches for the staged runtime JSONs in:

- `/var/jb/Library/Application Support/WATweaks/runtime`
- `/Library/Application Support/WATweaks/runtime`
- app bundle `runtime/` fallbacks

Each inventory file becomes a `WAGRSurfaceSpec` and is opened by `WAGRSurfaceBrowserVC`.

The browser merges two sources:

1. Runtime-validated ObjC BOOL no-arg methods from live classes.
2. Static WAAB flags from inventory JSON, stored through the existing `wagr.waab.<flag>` mapping.

WAAB inventory rows do not require a direct selector method. They call `WAGRWAABEnsureHooksInstalled()` and rely on the existing `boolForKey:defaultValue:` / `stringForKey:defaultValue:` fallback hooks.

ObjC method rows are only hook-installed when a BOOL no-arg selector exists in the current process.

## Why this matters

The import/export layer should read this same inventory layer later instead of exporting arbitrary `NSUserDefaults` keys. This keeps WAAB, WAContext, WAAura, WAServerProperties, FOA and WABiz grouped consistently.
