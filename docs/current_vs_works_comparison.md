# WATweaks atual vs works comparison

This comparison was used to avoid carrying forward the broken duplicated-menu architecture.

- Files only in atual: 43
- Files only in works: 8
- Files changed between both: 24

## Important differences

- `works` had the simpler runtime/object scanner files (`WAGRObjectGraphScanner`, `WAGRObjCHookRouter`) but targeted an older WhatsApp build.
- `atual` added GateStore/WAAB persistence and SDK 26.2 LiquidGlass work, but also accumulated duplicated runtime/category menus and Developer-menu UI mutation hooks.
- The refactor keeps the useful current GateStore/WAAB persistence, removes Developer-menu UI mutation, and replaces runtime browsing with two real image-backed scanners: executable and SharedModules.

## Files only in works (first 40)

- `.github/workflows/build-watweaks.yml`
- `src/Hooks/WAGRObjCHookRouter.xm`
- `src/Menu/WAGRGatingAreaMenuVC.h`
- `src/Menu/WAGRGatingAreaMenuVC.m`
- `src/Menu/WAGRGatingCatalog.h`
- `src/Menu/WAGRGatingCatalog.m`
- `src/Runtime/WAGRObjectGraphScanner.h`
- `src/Runtime/WAGRObjectGraphScanner.m`

## Files only in atual (first 60)

- `.github/workflows/buildtweak.yaml`
- `ANALYSIS_REPORT.md`
- `REFACTOR_NOTES.md`
- `docs/BUILD_PRECHECK.md`
- `docs/LINK_PRECHECK.md`
- `docs/WAGR_RUNTIME_PREFIX_CLASSIFIER.md`
- `docs/abprops_native_row_replacement.md`
- `docs/debugmenu_instrumentation_analysis.md`
- `docs/internal_employee_dogfood_gate_fix.md`
- `docs/native_debug_menu_activation.md`
- `docs/patch_apply_regression_fix.md`
- `docs/private_abproperties_constructor_probe.md`
- `docs/private_experimentation_debug_overrides.md`
- `docs/private_experimentation_dynamic_offsets.md`
- `resources/runtime/WAABPrefixCategories.json`
- `src/Hooks/WAGRAuraNavigationHooks.xm`
- `src/Hooks/WAGRDebugMenuInstrumentation.xm`
- `src/Hooks/WAGRDebugMenuQuickAccess.xm`
- `src/Hooks/WAGRGateHooks.xm`
- `src/Hooks/WAGRGlobalGateStub.xm`
- `src/Menu/WAGRABPropsRootVC.h`
- `src/Menu/WAGRABPropsRootVC.m`
- `src/Menu/WAGRGateCategoryVC.h`
- `src/Menu/WAGRGateCategoryVC.m`
- `src/Menu/WAGRGateRuntimeBrowserVC.h`
- `src/Menu/WAGRGateRuntimeBrowserVC.m`
- `src/Menu/WAGRLogViewController.h`
- `src/Menu/WAGRLogViewController.m`
- `src/Menu/WAGRMainSettingsVC.h`
- `src/Menu/WAGRMainSettingsVC.m`
- `src/Menu/WAGRMenuTheme.h`
- `src/Menu/WAGRMenuTheme.m`
- `src/Menu/WAGRRuntimeGatesVC.h`
- `src/Menu/WAGRRuntimeGatesVC.m`
- `src/Runtime/WAGRGateRegistry.h`
- `src/Runtime/WAGRGateRegistry.m`
- `src/Runtime/WAGRGateStore.h`
- `src/Runtime/WAGRGateStore.m`
- `src/Runtime/WAGRLog.h`
- `src/Runtime/WAGRLog.m`
- `src/Runtime/WAGRRuntimeClassifier.h`
- `src/Runtime/WAGRRuntimeClassifier.m`
- `src/Runtime/WAGRRuntimeCompat.m`