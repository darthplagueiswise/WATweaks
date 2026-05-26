# PrivateABProperties constructor probe

This diagnostic step was added after `WAContextMain.debugPropOverrides` was forced non-nil and the native `PrivateExperimentationDebugViewController` still initialized with an empty Swift existential container.

The probe does not write to Swift ivar offsets and does not replace the native debug UI. It calls the ObjC-exposed initializers on:

```objc
_TtC24WAPrivateExperimentation19PrivateABProperties
```

with the same dependencies collected from the live `WAContextMain`:

```objc
abProperties
preferences
accountProvider
debugPropOverrides
userContext
```

Expected log markers:

```text
[PreFlight][PrivateAB] deps ...
[PreFlight][PrivateAB] initWithPropertiesStore:debugOverrides: -> ...
[PreFlight][PrivateAB] initWithPreferencesStore:accountProvider:debugOverrides:userContext: -> ...
```

If both constructors return a real `PrivateABProperties` object, then the remaining failure is inside the hidden Swift-only `PrivateExperimentationManager` constructor path, not the `debugPropOverrides` nil check.

If either constructor throws or crashes, the exception/crash reveals which dependency type the Swift initializer actually expects.
