# Startup hot-path fix — Watusi strict model

Based on the provided Watusi binary analysis, constructors/initializers should install fixed hook batches synchronously during dylib load, but must not run runtime probes, NSUserDefaults migrations, dictionaryRepresentation scans, or timed retry cascades.

Applied policy:

- Tweak.x startup owns only global UI activation gestures.
- Dedicated hook owners install fixed hooks from their own constructors.
- No Tweak.x re-entry into WAGRGate/Aura/AccountEligibility/NativeDevMenu owners during startup.
- No dyld add-image callback fanout for the gate/Aura/account/liquid-glass owners in the hot path.
- No UIApplicationDidFinishLaunching observer that performs WAGRWipeLegacyStorageIfNeeded or persisted restore on launch.
- WAGRContextMenuPipelineProbeCtor remains present but inert; runtime probe/objc_copyClassList stays on demand only.
- NSUserDefaults migration/restore is no longer part of app open.

This intentionally prioritizes launch speed. Late or optional runtime work is triggered by menu/toggle actions, not automatically during startup.
