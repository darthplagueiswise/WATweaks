# WhatsApp 26.33 native Developer surface map

This document records the current `WhatsApp(7)` / `SharedModules(7)` result.
It separates surviving native owners from code removed or stubbed in the
release-candidate build. A selector name or string by itself is not treated as
a working menu.

Analyzed images:

- `WhatsApp(7)` SHA-256
  `01a3049eb1994a7bfe3cd09089bdf24faaded9818b83e1b02dd7491ab840d77c`;
- `SharedModules(7)` SHA-256
  `b95c66b5d27476d323aaa1ba761fb76aa07f2df5b8f10d482ea6fd6953f6619a`.

## Surviving native Developer owner

The application still owns this complete navigation chain:

```text
WAContextMain
  -> WADebugMenuMain.DebugMenuProvider
  -> debugViewController / presentDebugControllerIfNeeded
  -> WADebugViewController(initWithUserContext:)
  -> createSections
```

`DebugMenuProvider` still implements `isDebugMenuAllowed`,
`isDebugMenuShortcutEnabled`, `debugViewController`, and
`presentDebugControllerIfNeeded`. WATweaks enables the exact gates before the
application builds its sections; it does not replace the Developer root.

## AB Properties: removed UI, surviving backend

The 26.33 RC removed all of the following:

- Objective-C class `WADebugABPropertiesTableViewController`;
- `-[WADebugViewController showABProperties]`;
- `-[WADebugViewController showABPropertiesTable]`.

`-[WADebugViewController createSections]` instead compiles one `AB Props`
section, one `WATableRow`, and the release-candidate warning directly. The
backend remains present:

- `-[WAContext(ABProperties) abProperties]`, ABI `@16@0:8`;
- account-scoped `WAABProperties` and its `gabp.o` `WAPropertiesStore`;
- generated typed getters with stable IDs encoded in their ARM64 thunks;
- `WAMCEvaluation` and `FBMobileConfigStartupConfigs` mapping/writer APIs.

`-[WAContext(WAPropertiesShared) debugPropOverrides]` is not an alternative
hidden writer in this RC. Its implementation at `0x101818` tail-branches to
the nil-return stub at `0xa698`. Both `WAProperties` and `WAABProperties`
retain the `initWithPropertiesStore:debugOverrides:` ABI, but the current
context supplies no debug-overrides object.

The compatibility repair therefore registers the missing class under its
exact runtime name with `objc_allocateClassPair`, using the loaded
`WAStaticTableViewController` as its actual superclass. It restores the two
historical navigation selectors and passes the exact
`WAContext.abProperties` object into the controller. The recreated class is
scoped only to that receiver. It does not inherit from the generic WATweaks
browser and does not merge Private AB Props, shared singletons, or
server-property candidates into the table.

The rest of the controller follows the surviving WhatsApp debug-menu ABI:

- content is represented by `WATableSection` and `WATableRow`;
- rows use `WADebugMenuBase.WADebugKeyValueTableViewCell`;
- search implements `WASearchControllerDelegate` and uses
  `WASearchController`;
- editing uses `WADebugInputViewController` with its native
  `possibleValues` support.

The existing RC `AB Props` section and its single row are retained. Only that
row's obsolete warning presentation is changed back into the
`showABProperties` navigation action. No preset, Private Experimentation,
Export/Import, or WATweaks root rows are appended to the Developer section.

## Editing contract

Only generated getters whose current ARM64 thunk resolves a stable ID enter
the recreated table. Values are read lazily for visible search results and the
selected editor, preventing controller construction from invoking every
generated getter at once. Applying a value uses:

```text
WA stable ID
  -> WAMCEvaluation.getMCSpecifierForStableId:
  -> FBMobileConfigStartupConfigs.convertSpecifierToParamName:
  -> FBMobileConfigStartupConfigs.setOverrideForParam:andValue:
  -> App Group persistence verification
  -> account UserSession invalidation
  -> typed effective-value readback
```

Failure at any verification step reverts the attempted write. This Developer
controller does not install a WAAB getter swizzle as a fallback.

## Other native internal surfaces

| Surface | 26.33 status | Activation policy |
|---|---|---|
| Developer root | Controller/provider present | Enable provider/internal/debug-build gates before native construction |
| AB Properties | UI class/navigation removed; backend present | Recreate removed class/selectors; retain native section/row |
| Private Experimentation | Native Swift controller present | Keep separate and let its native owner instantiate it |
| Bug Report / Rage Shake | Native controllers/coordinator present | Enable exact employee, bug-report, and rage-shake gates; do not duplicate UI |
| Dogfood Settings entry | Native strings/consumer gates present | Enable exact dogfood entrypoint gates before Settings rebuild/relaunch |
| MobileConfig | Backend, StartupConfigs, context managers and gates present; dedicated debug controller not proven | Enable surviving gate; do not fabricate a controller |
| Thirteen `Set ABProps` groups | Compiled Swift data/consumer artifacts present; no stable callable URL grammar proven | Retain as analysis evidence only; do not expose guessed deep links |

## Build 581 regression

Build 581 did not perform this reconstruction. It replaced the `AB Props`
section with WATweaks-owned preset/configuration rows and guessed three
`setabprops` URL forms. Device evidence showed that `WADeepLinkParser` returned
no `WAABPropDeepLink`. Those rows, the separate “Native Debug Presets” screen,
and the URL bridge are removed from the source and guarded by CI invariants.
