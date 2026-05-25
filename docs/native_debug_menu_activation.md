# Native Debug Menu activation

This build targets WhatsApp's real internal debug stack, not a fake WAAB menu.

Static analysis of `WhatsApp(10)` and `SharedModules(14)` confirmed the native path:

```text
WAContext / userContext
  -> debugMenuProvider
  -> _TtC15WADebugMenuMain17DebugMenuProvider
  -> isDebugMenuAllowed
  -> debugViewController / presentDebugControllerIfNeeded
  -> WADebugViewController
```

The AB/private experimentation surface is also native:

```text
_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController
  - initWithUserContext:
```

## Rules

1. Do not create a fake WAAB menu.
2. Do not do mass WAAB/runtime scans at startup.
3. Capture `userContext` only after Settings/app UI exists.
4. Resolve `debugMenuProvider` from the native context/provider path.
5. Use WAAB only as support gates for the native UI.

## Forced support gates

The launcher primes these gates only when the user explicitly opens the native menu/private experimentation:

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

`serverPropsDisableExperimental` is intentionally forced OFF because the native `isDebugMenuAllowed` path references it as a blocker.

## Opening order

`WAGRLaunchNativeDeveloperMenu` tries:

1. `[provider presentDebugControllerIfNeeded]`
2. `[provider debugViewController]` and present/push the returned VC
3. `[[WADebugViewController alloc] initAsModalWithUserContext:]`
4. `[[WADebugViewController alloc] initWithUserContext:]`
5. `[[PrivateExperimentationDebugViewController alloc] initWithUserContext:]`

`WAGRLaunchNativePrivateExperimentation` opens the private experimentation VC directly with the same live `userContext`.

## Ownership

- `WAGRNativeDevMenuHooks.xm`: native gate owner and support-gate activation.
- `WAGRDebugMenuLauncher.xm`: context/provider resolution and native opening.
- `WAGRSurfaceListVC.m`: UI actions only.
- `WAGRGateHooks.xm`: WAAB bool/string hook support; no fake AB menu.
