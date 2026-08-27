# Verified WhatsApp iOS ABProps / MobileConfig pipeline

Build artifacts analyzed directly on 2026-08-26:

- `WhatsApp(5)` SHA-256 `9f08516fa766f3697a54804207721d5bf14fbc5a22d6930236e43510e44ee7af`
- `SharedModules(5)` SHA-256 `f0edef076c68d7f1f872401d774789a2cb3f50be5c96773a2d8ed763ed3015a7`

This document records only relationships supported by those Mach-O images and by the native launch log. It is deliberately narrower than earlier experimental notes.

## 1. ABProps server/cache path

`SharedModules` contains the following native components in the same build:

- `XMPPConnectionABPropsRequestManager`
  - `requestFreshABProps:withCompletion:`
  - `requestFreshABPropsWithGroupJID:deltaUpdate:completion:`
- `WAProperties`
  - property update/delta update entry points
- `WAPropertiesStore`
  - `getPreferencesStore`
- account-scoped `gabp.*` keys
- suite `group.net.whatsapp.WhatsApp.shared`
- queue label `com.whatsapp.properties-store.`

The supported model is therefore:

```
ABProps request/response
        ↓
WAProperties update / delta-update
        ↓
WAPropertiesStore
        ↓
account-scoped gabp.* cache + metadata
        ↓
group.net.whatsapp.WhatsApp.shared preferences domain
```

Do **not** treat `gabp.*p/c` as WATweaks' persistent override database. It is WhatsApp's server-backed ABProps cache/state and is allowed to be refreshed or replaced by the app.

The current static analysis does not claim that `requestFreshABProps:` itself is the final physical-plist writer. The request flows through WAProperties/store abstractions first; preferences/cfprefsd may materialize the file.

## 2. ABProp → MobileConfig translation

The current `SharedModules` contains:

- `WAMCEvaluation`
  - `getMCSpecifierForStableId:`
  - `getWAStableIdToParamSpecifierEntries`
- `FBMobileConfigContextManager`
  - `getStableIdFromParamSpecifier:`
  - `getTranslatedSpecifier:`
  - `getOverridesTablePath`
- `FBMobileConfigOverridesTable`
- `FBMobileConfigManager::initMobileConfigManagerWithOverrides`
- literals `mc_overrides.json` and `id_name_mapping.json`

The stable mapping chain used by WATweaks must be:

```
WA ABProp stable ID / wire code
        ↓
WAMCEvaluation getMCSpecifierForStableId:
        ↓
64-bit MobileConfig paramSpecifier
        ↓
FBMobileConfigContextManager getStableIdFromParamSpecifier:
        ↓
external MobileConfig config stable ID
        +
parameterIndex encoded by the paramSpecifier
        ↓
mc_overrides.json
```

Never use the ABProp code or `localConfigIndex` as the top-level key in `mc_overrides.json`.

The previously decoded paramSpecifier fields remain useful for diagnostics (including parameter index and native type), but the **external config stable ID must come from the live MobileConfig context manager**.

## 3. Native override bridge

The current `WhatsApp` executable contains:

- `WAMobileConfigABPropsOverridesSync`
  - `syncABPropsOverridesToMCWithUserContext:`
  - `overriddenStableIdsWithUserContext:`
- `debugABPropsOverrider`
- `abpropEnabledOverride`

This is evidence of a native ABProps-debug-override ↔ MobileConfig synchronization layer. It supports using MobileConfig as the persistent override path rather than installing one swizzle for every generated `WAABProperties` getter.

Do not call undocumented native methods merely because the selector exists. Resolve the object/method kind and Objective-C ABI first, then validate readback.

## 4. Native MobileConfig path observed at launch

The native launch log prints the MobileConfig overrides table path and the resolved `mc_overrides.json` file under the WhatsApp shared AppGroup `Documents/mobileconfig` hierarchy. This confirms that the app's normal MobileConfig initialization reads an overrides file from that context.

Run 461 already contains the safer WATweaks resolver path:

1. acquire a live `FBMobileConfigContextManager` (captured account context when available, with validated fallback managers),
2. translate ABProp stable ID through `WAMCEvaluation`,
3. resolve external config stable ID through `getStableIdFromParamSpecifier:`,
4. use the paramSpecifier's parameter index,
5. write the native `mc_overrides.json` path atomically.

Keep this as the persistent path.

## 5. Cold-start rule after the 461→476 regression

The last known device-working baseline was GitHub Actions run 461, commit:

`dd38aaf0d95e016b5c9e454390075d14a47e9c02`

Runs 462–476 introduced broad RuntimeValueStore/browser changes. The affected build compiled but the app could remain alive on a black screen during launch; the captured log reaches `finishLaunchingWithOptions-start` without a matching observed end and also shows severe launch memory pressure.

Consequently:

- no runtime class catalog build in constructors;
- no ivar/method/property graph enumeration in constructors;
- no arbitrary persisted per-selector `WAGRRuntimeValueReinstallPersistedHooks()` in constructors;
- browser discovery is on-demand;
- ABProp persistence should prefer native MobileConfig translation/file state;
- runtime hooks, when needed, are immediate/session behavior and must not become a thousands-of-hooks launch mechanism.

`scripts/wagr_validate_cold_start.py` enforces the constructor portion of this policy during every build.

## 6. What is not claimed

This document does **not** claim that:

- fresh ABProps fetch generates `mc_overrides.json`;
- `requestFreshABProps:` directly writes the physical shared plist;
- an ABProp wire code equals an external MobileConfig stable ID;
- build success proves runtime launch safety;
- every internal/dogfood feature is controlled by one master ABProp.

Those were sources of earlier false conclusions and must not be reintroduced.
