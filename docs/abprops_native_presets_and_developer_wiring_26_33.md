# WhatsApp 26.33 Developer AB Properties reconstruction

## What the binaries actually contain

The 26.33 release-candidate `WADebugViewController -createSections` compiles
the yellow “AB Props are not available in release candidate builds” message
directly. It is not produced by a nil `wamo_abprops_list`.

The old `WADebugABPropertiesTableViewController` class and the
`showABProperties` / `showABPropertiesTable` methods are absent from both
analyzed 26.33 executables. The SharedModules string
`_custom_WADebugABPropertiesTableViewController_1` is only a color token.

The account-scoped backend was not removed:

- `WAContext(ABProperties) -abProperties` has ABI `@16@0:8`;
- the returned object is `WAABProperties` in the device runtime;
- its `WAPropertiesStore` identity is `gabp.o`, type 1, personal account;
- the supplied runtime capture contains 5,936 effective properties;
- generated getters still encode their decimal stable IDs in the verified
  ARM64 thunk before tail-branching to the typed property reader.

## Reconstructed native class contract

The first reconstruction incorrectly compiled the removed class as a subclass
of `WAGRABPropsBrowserVC`. That preserved only a class name; it did not restore
the WhatsApp controller family or its table/search lifecycle.

The corrected implementation registers
`WADebugABPropertiesTableViewController` with `objc_allocateClassPair`, using
the loaded `WAStaticTableViewController` as its real superclass. This avoids an
SDK-time private-framework link while producing the same runtime superclass
relationship used by WhatsApp's debug controllers. Its initializer retains the
exact `WAContextMain` and `WAContext.abProperties` objects supplied by the
native Developer controller.

The contract is supported by two independent sources:

- the current 26.33 Mach-O retains `WAStaticTableViewController`,
  `WATableSection`, `WATableRow`, `WASearchController`,
  `WADebugInputViewController`, and the Swift
  `WADebugKeyValueTableViewCell` class;
- the public WhatsApp class dump at
  `IlannM/WhatsAppHeaders` records
  `WADebugViewController : WAStaticTableViewController
  <WASearchControllerDelegate>` and the complete search delegate selector
  family. Its `WADebugInputViewController` header records
  `initWithCompletionHandler:`, `initialText`, `keyboardType`, and
  `possibleValues`.

At hook installation, only the missing historical navigation contract is
restored on `WADebugViewController`:

```text
showABProperties
    -> showABPropertiesTable
        -> WAContext.abProperties
        -> WADebugABPropertiesTableViewController
```

If either selector unexpectedly exists with a non-stub implementation in a
later build, WATweaks leaves it untouched. Replacement is permitted only when
the method is absent or shares the verified RC no-op IMP used by
`resetAllOverriddenABProps`.

`createSections` continues to come from WhatsApp. Its machine code creates the
`AB Props` section and one row with `-[WATableSection addDefaultTableRow]` before
configuring the release-candidate warning. WATweaks reuses that exact section
and row object, replaces only the removed label/handler, and clears the obsolete
warning footer. It does not call `setRows:`, append rows, inject presets,
Private Experimentation, Export/Import, or another root menu into that section.

The recreated table scans only the exact account `WAABProperties` receiver.
Only selectors with a stable ID decoded from the generated getter thunk enter
the native `WATableSection` / `WATableRow` model. Rows use
`WADebugKeyValueTableViewCell`; search is provided by
`WASearchControllerDelegate`; and selection opens
`WADebugInputViewController`, including its native `possibleValues` list for
booleans. Families come from the generated selector namespace and do not use a
bundled stale catalog.

Effective getter values are read lazily for visible native rows, visible search
results, or the selected editor. The controller does not eagerly call thousands
of generated getters while constructing its static sections. Typed editing uses the verified native
path `stable ID -> WAMCEvaluation -> FBMobileConfigStartupConfigs`, requires
App Group persistence, invalidates the account UserSession, and confirms the
effective getter. A tracked override can be cleared through the native editable
row. There is no WAAB method-swizzle fallback.

## Why build 581 failed

Build 581 did not recreate the removed controller. It replaced the native
section with thirteen WATweaks rows and guessed three URL shapes for each
compiled preset group. Device screenshots prove that `WADeepLinkParser`
returned no `WAABPropDeepLink` for those URLs. Those guessed URLs, the custom
“Native Debug Presets” controller, and its bridge have been removed.

The thirteen `Set ABProps` artifacts still exist in the executable, but that
fact is not equivalent to a supported public URL grammar. Several tuple names
are no longer generated WAAB getters in this RC, and Business Assistant is an
actual empty array. They are retained as reverse-engineering evidence only;
they are not presented as working Developer actions.

## Other internal surfaces

Developer, Private Experimentation, MobileConfig, WAMO, Dogfood, Bug Report,
and Rage Shake remain separate owners. Their surviving native gates and
controllers are prepared before WhatsApp builds its sections. None of those
surfaces substitutes for `WADebugABPropertiesTableViewController`.

Export/Import remains available in the WATweaks ABProps utility area because it
was explicitly requested, but it is no longer injected into WhatsApp's native
Developer `AB Props` section.
