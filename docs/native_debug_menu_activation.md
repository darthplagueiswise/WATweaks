# Native WhatsApp Developer / Private Experimentation activation

This patch targets the native WhatsApp debug stack confirmed in `WhatsApp(10)` and `SharedModules(14)`:

```text
WAContext / provider
  -> debugMenuProvider
  -> _TtC15WADebugMenuMain17DebugMenuProvider
  -> debugViewController / presentDebugControllerIfNeeded
  -> WADebugViewController
```

The native Private Experimentation controller is also present:

```text
_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController
  - initWithUserContext:
  - tableView:numberOfRowsInSection:
  - tableView:cellForRowAtIndexPath:
  - tableView:didSelectRowAtIndexPath:
```

## Confirmed AB Props finding

A second binary pass over `WADebugViewController -createSections` shows that this release-candidate build does create a native `AB Props` section title, but the section body is compiled as the release-candidate placeholder path.

Confirmed in `createSections`:

```text
0x101722180  WADebugViewController -createSections
0x1017221e8  CFString "AB Props"
```

The strings for the real rows:

```text
Private Experimentation Debug
Allocated AB Props
Sync Experiments
Fetch Experiments
ABProp Allocation
Is ABProp allocated?
Clear Private AB Props
```

are not referenced by `WADebugViewController -createSections`. They are referenced by the native `PrivateExperimentationDebugViewController` range around `0x104006700`.

That means there is no confirmed runtime branch inside this RC `createSections` that can simply be flipped to reveal a hidden full AB Props controller. The full native AB/private-experimentation UI that exists in this binary is `PrivateExperimentationDebugViewController`.

## What this patch intentionally does

- It does not create a fake WAABProperties menu.
- It does not scan WAABProperties at startup.
- It unlocks the native `DebugMenuProvider` / `WADebugViewController` path.
- It captures `userContext` only after Settings / WAContext exists.
- It opens the native Private Experimentation controller with `initWithUserContext:`.
- It forces only the required support gates through `WAGRGateStore` on explicit user action.

Support gates activated before opening native debug UI:

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

## What this patch intentionally does not do

The previous experimental patch injected custom rows into the native Developer table section 0. That was wrong for the stated goal because it replaced the release-candidate placeholder with WATweaks-owned rows.

This patch does not hook:

```text
WADebugViewController tableView:numberOfRowsInSection:
WADebugViewController tableView:cellForRowAtIndexPath:
WADebugViewController tableView:didSelectRowAtIndexPath:
```

It also does not replace section 0 of `WADebugViewController` with custom cells.

If a future internal/alpha binary contains the real AB Props branch inside `createSections`, the correct fix is to analyze that binary and hook the actual branch condition. In this RC binary, that branch was not confirmed.
