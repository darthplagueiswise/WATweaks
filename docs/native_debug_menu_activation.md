# Native WhatsApp Developer / Private Experimentation activation

This branch targets WhatsApp's native Developer stack, not a fake WAAB browser.

Confirmed binary path from `WhatsApp(10)` / `SharedModules(14)`:

```text
WAContext / provider
  -> debugMenuProvider
  -> _TtC15WADebugMenuMain17DebugMenuProvider
  -> debugViewController
  -> WADebugViewController
```

The native Private Experimentation controller is:

```text
_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController
```

## Gates forced only when the user opens native debug UI

`WAGRNativeDebugActivateSupportGates()` writes these through `WAGRGateStore` only on explicit user action:

```text
isDebugMenuAllowed -> YES
isDebugMenuShortcutEnabled -> YES
waios_mc_debug_ui_enabled -> YES
whatsbroken_enabled -> YES
private_abprop_for_dev_only -> YES
private_experimentation_should_sync -> YES
dogfooding_nudge_settings_entrypoint_enabled -> YES
serverPropsDisableExperimental -> NO
```

No mass WAAB scan is performed at startup.

## AB Props block in release-candidate builds

Flex confirmed that the visible Developer screen is:

```text
WACustomBehaviorsTableView
  dataSource = WADebugViewController
```

The yellow warning cell is in:

```text
section 0, row 0
```

with text similar to:

```text
AB Props are not available in release candidate builds.
```

The safe patch point is therefore not a fake WAAB menu and not a raw WAAB scan. The tweak hooks `WADebugViewController`'s native table data source/delegate methods:

```objc
-tableView:numberOfRowsInSection:
-tableView:cellForRowAtIndexPath:
-tableView:didSelectRowAtIndexPath:
```

For section `0`, it replaces the single release-candidate placeholder row with native navigation rows:

```text
Allocated AB Props
Private Experimentation Debug
```

Selecting either row opens WhatsApp's own `PrivateExperimentationDebugViewController` with the live `userContext`.

This keeps the target native:

```text
DebugMenuProvider + WADebugViewController + PrivateExperimentationDebugViewController
```

WAABProperties remains only a gate/value support layer.

## Startup rule

Do not add:

```text
dispatch_after startup retries
_dyld_register_func_for_add_image startup fanout
objc_copyClassList in constructors
mass class/method scans in constructors
WAAB browser/menu clones
```

The constructor path installs fixed, narrow hooks only.
