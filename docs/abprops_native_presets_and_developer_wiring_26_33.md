# WhatsApp 26.33 native ABProps and internal-surface wiring

## Binary result

The release-candidate `WADebugViewController -createSections` compiles the
yellow “AB Props are not available in release candidate builds” placeholder
directly. It is not produced by `wamo_abprops_list == nil`.
`WADebugABPropertiesTableViewController` is absent as an instantiable class;
`_custom_WADebugABPropertiesTableViewController_1` is only a color token.

The RC still contains all of these native components:

- the 13-element Swift `Set ABProps` group array;
- `WAABPropDeepLink`, with Swift fields `setABPropsHost` and
  `abPropsGroupName`;
- `WADeepLinkParser -deepLinkWithURL:context:`;
- `WAABPropDeepLink -handleDeepLinkWithRootVC:`, which loads the native array,
  shows the native confirmation, and applies its selector/value tuples;
- `PrivateExperimentationDebugViewController` and its Allocated AB Props,
  Fetch, and Sync surfaces;
- WAAB/MobileConfig backends and the original Settings, Bug Report, Rage Shake,
  Dogfood, WAMO, Internal, and Developer builders that survive in this RC.

The preset host literal is `setabprops`. WATweaks now feeds
`whatsapp://setabprops/<group>` through `WADeepLinkParser`, requires the parsed
object to be a `WAABPropDeepLink`, and then invokes its public Objective-C
handler. No preset pair is copied into the Developer hook and no StartupConfigs
writer is substituted for the app's consumer.

## Preset groups

The compiled group identifiers are:

1. `smbmktmsgs`
2. `smbmetaverifiedphase1a`
3. `smbmetaverifiedphase1b`
4. `smbbusinessassistant`
5. `mv_storekit2`
6. `mv_partner_billing`
7. `iap_codegen_and_parse_errors`
8. `smb_premium_broadcast`
9. `disable_smb_premium_broadcast`
10. `smb_send_limit`
11. `disable_smb_send_limit`
12. `consumer_bl_capping`
13. `disable_consumer_bl_capping`

`smbbusinessassistant` is a genuine `Array.empty` entry in this RC. It remains
visible because it is present in WhatsApp's native array; WATweaks does not
invent AI flags. Partner Billing and the dynamically interpolated
`smb_subscription_config` are consequently owned by the native consumer too.

## Developer, Internal, MobileConfig, Dogfood, and Bug Report

The native menu hook prepares the exact gates before WhatsApp calls its own
section builders. This order matters: changing them after `createSections`
cannot resurrect rows that the app already skipped.

| Surface | Native owner / effective gates |
|---|---|
| Developer | `DebugMenuProvider` and `WADebugViewController` |
| MobileConfig / Internal settings | `waios_mc_debug_ui_enabled`, `whatsbroken_enabled` and the original plugin/section builders |
| Private Experimentation | native Swift controller plus `privateABProperties` from the account `userContext` |
| Dogfood | `dogfooding_nudge_settings_entrypoint_enabled`, banner/privacy/task-ID gates |
| Bug Report / Rage Shake | `ios_internal_in_app_bug_reporting_enable`, `ios_internal_rage_shake_enabled` and native `WABugReport` / `WARageShakeSheetObjCBridge` |
| WAMO | `wamo_enabled`, `wamo_debug_tool_enabled`, tester/employee and demo gates |
| Debug build identity | `KmpAppleBuildInfo -getBuildType` with the real debug enum |

The Developer `AB Props` section remains the original `WATableSection`. Its RC
warning rows are atomically replaced by 13 native deep-link actions, the native
Private Experimentation controller, and the explicitly requested WATweaks
backup utility. The removed historical table controller is not falsely claimed
to exist.

The context instrumentation is read-only. In particular, it no longer changes
`isPrimaryDevice` and no longer fabricates an empty `debugPropOverrides`
dictionary.

## Export crash and regression guard

Build 580 crashed while exporting on a global user-initiated queue:

```text
SharedModules -[WAPropertiesStore init] + 0x8c
WAGRRuntimeValueRead + 1536
WAGRABPropsCurrentValue + 172
```

The old catalog treated any zero-argument supported-return method as a getter.
Its broad stable-ID search crossed ordinary method instructions and admitted
`-[WAPropertiesStore init]`; Export then called the initializer as a property
getter off-main, producing `EXC_BREAKPOINT / SIGTRAP`.

The fixed catalog only accepts the verified 26.33 generated-getter thunk:

```text
ADRP x2, stableIDCFString@PAGE
ADD  x2, x2, stableIDCFString@PAGEOFF
[optional default in x3]
B    typed *ForKey:defaultValue: implementation
```

Lifecycle selectors are independently denied by the generic runtime store.
Runtime-object resolution, catalog scanning, every live getter read, native
mapping, and native write/rollback are marshalled to the main thread. JSON
serialization and file I/O remain off-main.

## Portable export/import

The config document records class, selector, class/instance method, encoding,
image, stable ID, effective value, and verified override state for each
validated generated getter. Import still offers:

- restore only exported overrides;
- apply the full importable effective snapshot.

Both modes revalidate class/selector/stable-ID/native mapping before the first
write. They do not edit `gabp.*p` or manufacture `mc_overrides.json`.
