# WAGR Runtime Prefix Classifier

This patch keeps the Runtime Avançado path as the single source of truth. It does not use the old WAAB catalog screens and does not load `waab_selected_categories_*.json.gz` to drive the UI.

## What changed

New files:

- `src/Runtime/WAGRRuntimeClassifier.h`
- `src/Runtime/WAGRRuntimeClassifier.m`

Updated files:

- `src/Runtime/WAGRSurface.m`
- `src/Menu/WAGRSurfaceBrowserVC.m`
- `src/Menu/WAGRGateRuntimeBrowserVC.m`

## Behavior

Runtime rows are now grouped by selector/flag prefix and then by behavior subcategory, for example:

- `WAiOS — Negative · Disabled`
- `WAMO — Negative · Hide / Suppress`
- `XFAMG — Negative · Kill Switch`
- `GraphQL — Network / Fetch`
- `Private Experimentation — Experiment / Sync`
- `Internal / Dogfood — Internal · Employee / Dogfood`

The classifier is string-only and only runs when the Runtime UI scans. It does not add startup hooks, observers, timers, resource parsing, or binary scanning.

## Why resources were not changed

The current code only loads `resources/runtime/*.json` through `WAGRRuntimeInventory` for diagnostics/manifest usage. The live Runtime Avançado lists still come from `WAGRSurfaceSpec` + Objective-C runtime scanning, so the classifier belongs in `src/Runtime`, not in the compressed `waab_selected_categories_*.json.gz` catalogs.
