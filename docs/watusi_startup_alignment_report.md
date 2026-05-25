# Watusi startup alignment

Binary evidence from `Watusi.dylib` and `libWatusiToolsSL.dylib` shows the hook timing pattern:

- `Watusi.dylib` uses `__TEXT,__init_offsets` with 22 initializers.
- `libWatusiToolsSL.dylib` uses `__DATA,__mod_init_func` with 7 constructors.
- Constructors/initializers install hooks synchronously during dylib load.
- The constructor bodies resolve classes/selectors and call a hook wrapper.
- No constructor path touches `NSUserDefaults`, `dictionaryRepresentation`, or `synchronize`.
- Preference/defaults access exists in regular lifecycle code, not constructor hook batches.

Applied policy in WATweaks:

1. Constructor is hook-install only.
2. Core hook owners run one synchronous constructor batch.
3. Fixed `dispatch_after` retry cascades were removed from startup hook owners.
4. Existing dyld callbacks remain only for owners that already need late-image coverage.
5. `NSUserDefaults` migration/restoration remains outside constructor.
6. Runtime state for installed hooks stays in static flags/sets, not defaults.
7. User intent remains persisted in the canonical `watweak_*` store.

This mirrors the observed Watusi timing: hook now, prefs later.
