# Private Experimentation debugPropOverrides diagnostic

The in-app logs showed the real `WAContextMain` is captured correctly and exposes:

- `abProperties -> WAABProperties`
- `preferences -> WAPreferences`
- `accountProvider -> WAAccountProvider`
- `mobileConfig -> FBMobileConfigUserSessionContextManager`

The failing dependency is:

```text
ctx.debugPropOverrides responds=YES -> nil
```

The Private Experimentation manager constructor references `debugPropOverrides`, and the native controller comes back with its Swift-managed stored fields empty when this dependency is nil.

This patch adds a controlled diagnostic fallback in the existing ContextSpy hook:

```text
WAContextMain.debugPropOverrides nil -> NSMutableDictionary fallback
```

This is intentionally a diagnostic probe. If the native Swift path only requires a non-nil override container, the manager should initialize and the Private Experimentation table should render. If the native code expects a richer object conforming to `WADebugPropertiesOverriding`, the app may report an unrecognized selector or crash; that selector/class then identifies the real interface that must be implemented or resolved.

Do not write into Swift stored-property offsets such as `manager@0x8`, `privateABProperties@0x20`, or `abProperties@0x28`. Those are Swift-managed containers and should remain read-only for diagnostics.
