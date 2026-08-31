# Build 580 ABProps export crash — binary analysis

## Inputs

- Crash report: `WhatsApp-2026-08-30-192725.ips`
  - SHA-256: `23679c1393da6a32a61bdea0958ee9a1d3f99aebeb6776b5ca8deb5a9eca795d`
- Package: `WATweaks_dogfood2_rootless_580.deb`
  - SHA-256: `99f92598f3105f11c29d912925fa222100e6c856c4d73067e7fd338ea0ae0b2a`
- Extracted `WATweaks.dylib`
  - SHA-256: `d4ff5bc34368b5302c7b17fc45cbf7242eda86dca9d2286ee2a5a5689a3a0d93`
- WhatsApp 26.33 executable: SHA-256
  `01a3049eb1994a7bfe3cd09089bdf24faaded9818b83e1b02dd7491ab840d77c`
- SharedModules 26.33: SHA-256
  `b95c66b5d27476d323aaa1ba761fb76aa07f2df5b8f10d482ea6fd6953f6619`

## Crash

The report identifies `EXC_BREAKPOINT (SIGTRAP)` on thread 31, queue
`com.apple.root.user-initiated-qos`. The relevant stack is:

1. SharedModules image offset `0x17929bc`
2. `WAGRRuntimeValueRead + 1536` (`WATweaks.dylib` offset `0x233c8`)
3. `WAGRABPropsCurrentValue + 172` (`WATweaks.dylib` offset `0xce68`)
4. the build-580 export worker (`WATweaks.dylib` offset `0xaf0b0`)

Objective-C metadata and function-boundary analysis resolve the SharedModules
address to `-[WAPropertiesStore init]`:

- function start: SharedModules `0x1792930`
- fault: `+0x8c`
- method encoding: `@16@0:8`

The exporter did not merely call a valid ABProp that failed. Its broad runtime
scanner admitted an initializer because it accepted every zero-explicit-argument
method with a supported return type. The old stable-ID resolver then searched up
to twenty ARM64 instructions for any nearby `ADRP/ADD` pair, so an ordinary
method body could be mistaken for a generated ABProp getter. Export invoked that
false entry on a global QoS queue and WhatsApp trapped in SharedModules.

## Correction

The runtime catalog now accepts only generated WAAB getter thunks with the
verified 26.33 ABI:

```text
ADRP x2, stableIDCFString@PAGE
ADD  x2, x2, stableIDCFString@PAGEOFF
[typed default materialization]
B    *ForKey:defaultValue:
```

Additional defenses:

- runtime objects/classes are restricted to actual WAAB/AB-properties providers;
- lifecycle selectors such as `init`, `new`, `copy`, `dealloc`, and `description`
  are rejected by the value reader and hook installer;
- the resolved stable ID is retained on the catalog entry and reused by export;
- account-scoped object resolution, scanning, getter execution, and Foundation
  value normalization run on the main thread; only JSON serialization and file
  I/O remain on the background worker;
- import mapping, writes, rollback, and clear operations are also marshalled to
  the main thread.

This fixes both independent defects visible in the crash: false getter identity
and off-main execution of WhatsApp's account-scoped property code.

## Developer UI correction after build 581

The build-580 custom preset writer failed on stale selectors and unresolved
stable IDs. Build 581 then replaced it with a different unverified assumption:
three guessed `setabprops` URL forms passed through `WADeepLinkParser`. Device
screenshots prove that none returned a `WAABPropDeepLink`. A compiled host
literal and a surviving handler did not establish the parser's URL grammar.

Both custom preset surfaces have therefore been removed. The 26.33 Developer
fix now registers the missing Objective-C runtime class
`WADebugABPropertiesTableViewController` with the loaded
`WAStaticTableViewController` as its actual superclass, restores the historical
`showABProperties -> showABPropertiesTable` navigation chain, and passes the
exact account-scoped `WAContext.abProperties` object into it. WhatsApp's native
`AB Props` section keeps its original `WATableSection` and original single
`WATableRow`; only that row's removed label/handler and the obsolete footer are
restored. It is no longer replaced by thirteen preset rows, Private
Experimentation, or WATweaks tools. Inside the controller, the table is built
with `WATableSection`, `WATableRow`, and
`WADebugKeyValueTableViewCell`; search uses `WASearchControllerDelegate`; and
editing uses `WADebugInputViewController` followed by native StartupConfigs
with persisted/effective readback. It has no generic WATweaks-browser
inheritance and no swizzle fallback.

The export-crash defenses above remain unchanged and are reused by the
reconstructed table: only verified generated getter thunks enter its catalog,
and the live account receiver is preserved explicitly.
