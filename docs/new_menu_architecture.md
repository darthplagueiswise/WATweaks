# New Menu Architecture (data-driven gating catalog)

This release introduces a curated, data-driven menu layer that replaces the
old "scan-everything-and-show-whatever-matches" approach. The motivation,
the components, and the extension contract are below.

## Why this exists

The previous menu surface had two problems. First, it produced UI by
scanning the runtime for classes that matched name patterns — so users
saw long lists of selectors with no semantic context, making it impossible
to know what each toggle actually did. Second, it had no notion of "area":
every feature ended up in the same flat browser, so there was no way to
think about Aura, LiquidGlass, hidden rows, or chat features as
independent surfaces.

The new layer fixes both by separating *declaration* (what gates exist
and what each one does) from *mechanics* (how the override is installed).
Declarations live in a single data file. Mechanics reuse the existing
WAGRObjCHookRouter without modification.

## Components

There are three new files under `src/Menu/`:

`WAGRGatingCatalog.h` defines the data model. A `WAGRGatingEntry` binds
a `(ClassName, selector, isClassMethod)` triple to a human-friendly
`title`, a `desc` line that explains what the gate controls, a
`WAGRGatingArea` tag for grouping, and an `inverted` flag for selectors
whose natural English reading ("show this") maps to the gate returning
NO. The header also exports area-level metadata helpers
(`WAGRGatingAreaTitle`, `WAGRGatingAreaIconName`, `WAGRGatingAreaSubtitle`)
that the UI uses to decorate each area row in the root menu.

`WAGRGatingCatalog.m` is the data file. Each area has its own
`entries_<Area>()` function that returns an `NSArray<WAGRGatingEntry *>`.
Two areas — Aura and HiddenRows — are populated with verified entries as
a working example of the format. The remaining seven areas exist as empty
stubs that the UI surfaces as "vazio (catálogo pendente)" so it is
visually obvious where to add more.

`WAGRGatingAreaMenuVC.{h,m}` is a generic table view controller that
takes a `WAGRGatingArea` at init time, loads that area's entries from the
catalog, and renders each entry as a UITableViewCell with a UISwitch
accessory. Toggling the switch writes the override key (using
`WAGROverrideKeyFor`, which mirrors the router's key format) and calls
`WAGRReinstallPersistedHooks()` so the change takes effect live.

## Adding a new gate

To expose a new feature toggle, edit `WAGRGatingCatalog.m`. Find the
`entries_<Area>()` function for the relevant area and add a row:

    [WAGRGatingEntry entryWithClass:@"WAExampleClass"
                           selector:@"isExampleFeatureEnabled"
                      isClassMethod:NO
                              title:@"Example Feature"
                               desc:@"Forces the example feature gate to YES."
                               area:WAGRGatingAreaAura
                           inverted:NO
                  availabilityClass:@"WAExampleClass"]

The `availabilityClass` field is for entries that target Swift classes
which may not exist on every build — when the class is missing at
runtime, the entry is filtered out of the UI rather than producing a
toggle that does nothing. Use `nil` for entries whose owning class is
always present.

## Adding a new area

To open a new section in the root menu, append a value to the
`WAGRGatingArea` enum in `WAGRGatingCatalog.h`, update the four area
metadata helpers (`WAGRGatingAreaTitle`, `WAGRGatingAreaIconName`,
`WAGRGatingAreaSubtitle`) in `.m`, and add the corresponding
`entries_<NewArea>()` function. The root menu auto-detects the new area
because it iterates `WAGRGatingAreaCount`.

## Relationship to the legacy bundle browser

The old "Categorias" section in `WAGRSurfaceListVC.m` is kept intact for
backward compatibility — it lives below the new "Áreas de Gating
(Curadas)" section. The validator script depends on the
`"Categorias"` string being present, so removing it would break CI.
Future iterations can deprecate the old section once the curated
catalogs cover the same ground.

## Override semantics

The catalog and the router share one persistence format:

    wagr.override|objc|<ClassName>|<inst|class>|<selectorName> = BOOL (YES/NO/absent)

When the switch in a catalog row is ON, the catalog writes YES. When it
is OFF, the catalog removes the key entirely. The router treats absent
keys as "no override" and lets the gate return WhatsApp's original
value. This three-state semantic (force YES / force NO / no override) is
preserved end-to-end.

For inverted entries — selectors like `shouldHideX` or `isXDisabled`
where the user-facing label "show X" maps to the gate returning NO — the
inversion is *not* baked into the persistence layer. The persisted value
is always YES when the user toggles ON; the router computes the physical
return value from the catalog's `inverted` flag at hook-call time. This
keeps the persistence format uniform and makes it possible to introspect
the override list without needing to know each entry's polarity.

## The three-strategy launcher

`WAGRDebugMenuLauncher.xm` was rewritten to try three increasingly
permissive strategies for opening the native developer menu. The first
two preserve WhatsApp's full Swift environment around the menu, so the
internal cells inside the menu are clickable; only the third strategy
(fresh instantiation) leaves some cells inert. The order is:

1. Locate the `DebugMenuProvider` Swift singleton via `WAContextMain` and
   call its `presentDebugControllerIfNeeded` method. This is the same
   entry point the app uses internally.
2. Switch the tab bar to the Settings tab and scroll the Developer row
   into view so the user can tap it natively.
3. Instantiate `WADebugViewController` fresh via `initWithUserContext:`
   and present it modally — last resort.

`WAGRDebugMenuLauncherDiagnosticText()` reports which classes are
present in the runtime, which is useful when a strategy fails and the
user wants to know whether the necessary classes are loaded.
