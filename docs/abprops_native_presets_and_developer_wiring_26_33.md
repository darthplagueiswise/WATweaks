# WhatsApp 26.33 ABProps presets and Developer wiring

## Result

The release-candidate `WADebugViewController -createSections` compiles the
yellow “AB Props are not available in release candidate builds” section
directly. It is not produced by `wamo_abprops_list == nil`, and setting build
type or TestFlight flags does not restore the removed controller.

`WADebugABPropertiesTableViewController` is not present as an instantiable
Objective-C/Swift class in this RC. `_custom_WADebugABPropertiesTableViewController_1`
is only a `WAColor` appearance token. The usable backends remain present:

- live `WAABProperties` getters and their ARM64 stable-ID descriptors;
- `WAMCEvaluation` and `FBMobileConfigStartupConfigs` typed overrides;
- `PrivateExperimentationDebugViewController`, initialized with the exact
  account `userContext`;
- a separate Swift internal surface containing 13 “Set ABProps to …” presets.

Therefore WATweaks preserves the native `AB Props` WATableSection and replaces
only its RC warning rows with four functional WATableRows: AB Properties /
Families, Native Debug Presets, Private Experimentation, and portable Export /
Import.

## Native preset dataflow

The 13-element Swift array is initialized in the main executable. A separate
Swift consumer loads that global, labels its action `Set ABProps`, and consumes
each `(selector, value)` array. That consumer is not the Developer placeholder
and this stripped RC exposes no stable class/selector ABI for invoking it. Raw
function offsets are intentionally not called: they are ASLR- and build-local.

The reconstructed UI uses the same data but resolves every selector against the
currently loaded runtime, decodes its stable ID from the current getter IMP,
and applies it through `WAGRABPropsNativeSetOverride`. The writer requires live
readback, App Group persistence, invalidation, and effective MobileConfig
readback; a failed batch is rolled back.

The presets are:

1. SMB Marketing Messages
2. SMB Blue Premium
3. SMB Meta Verified for prod
4. Meta AI for Business as Business Assistant
5. Meta Verified StoreKit2
6. Meta Verified Partner Billing
7. IAP GraphQL codegen and error parsing
8. Enable Business Broadcast
9. Disable Business Broadcast
10. Enable Business Broadcast Send Limit
11. Disable Business Broadcast Send Limit
12. Enable Consumer Broadcast List Capping
13. Disable Consumer Broadcast List Capping

The Business Assistant entry is a real compiled no-op in this RC: its payload
is `Array.empty`. It remains visible and cannot be applied. Inventing AI flags
would misrepresent the native preset.

Partner Billing is the seven StoreKit2 pairs plus:

- `wa_ios_iap_pb_payhub_enabled = true`
- `wa_ios_iap_pb_payhub_params_enabled = true`

## `smb_subscription_config`

The Blue/Meta Verified helper constructs this value dynamically as a JSON
string (not a JSON object):

```json
{
  "com.whatsapp.w4b.1000000000000000": {
    "purchase_origin": "meta_business_suite"
  },
  "com.whatsapp.mv4b.6937685799644206": {
    "purchase_origin": "in_app_purchase"
  }
}
```

It is applied to the runtime-resolved `smb_subscription_config` stable ID; no
`gabp.*p` or `mc_overrides.json` file is manufactured.

## Internal, employee, dogfood, bug report, and debug surfaces

These are independent gates/surfaces rather than one universal “internal” bit:

| Surface | Natural owner / gate | 26.33 result |
|---|---|---|
| Developer menu | `DebugMenuProvider` + native `WADebugViewController` | Present and used; AB Props rows reconstructed after `createSections` |
| AB Properties | `WAABProperties` / account MobileConfig | Backend present; old Debug table controller removed |
| Private Experimentation | native Swift `PrivateExperimentationDebugViewController` + `userContext.privateABProperties` | Present and launched with captured account context |
| Employee/Internal identity | `WAServerProperties +isInternalUser`, `is_meta_employee_or_internal_tester`, `is_internal_tester` | Exact gates are independently overridable; not treated as an AB table provider |
| Dogfood settings/nudges | `dogfooding_nudge_settings_entrypoint_enabled` and related WAAB getters | Native rows appear only when their own getters are effective |
| Bug reporting / rage shake | `ios_internal_in_app_bug_reporting_enable`, `ios_internal_rage_shake_enabled`, `rage_shake_eligible_via_bug_form`, fishfood/pathfinder/upload gates | Preserved as separate typed runtime families |
| Debug build type | `KmpAppleBuildInfo -getBuildType` | Telemetry/build gate only; cannot restore code removed from the RC |

The runtime-family browser exposes Internal, Employee, Dogfood, Fishfood, Bug
Reporting, Rage Shake, and Private Experimentation as live filters. It does not
claim that enabling one master switch materializes controllers missing from the
binary.

## Portable export/import

The WAAB config document records class, selector, class/instance method,
encoding, image, stable ID, effective value, and verified override state for
each live getter. Import offers two explicit modes:

- restore only exported overrides and remove other WATweaks-tracked native
  overrides;
- apply the entire importable effective snapshot as persistent overrides.

Both modes require the current class/selector to resolve to the same stable ID
and to a valid native mapping before the first write. A write failure rolls back
the values already changed in that batch.
