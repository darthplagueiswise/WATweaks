# ABProps native fetch + MobileConfig crosswalk v2

This note documents the dogfood2 correction for the native ABProps snapshot workflow.

## 1. Exact fresh-fetch entrypoint

The previous resolver accepted only Objective-C methods with 2 or 3 total arguments and could therefore never invoke the current WhatsApp entrypoint:

```objc
-[XMPPConnectionABPropsRequestManager
    requestFreshABProps:(BOOL)deltaUpdate
    withCompletion:(id)completion]
```

That selector has four Objective-C arguments in runtime metadata (`self`, `_cmd`,
`BOOL`, completion). `NO` selects the regular/config-hash branch; by itself it
does **not** mean “full”. The corrected path resolves the real manager, validates
that ABI, clears the exact account `WAProperties.configHash` through the active
native reset pair, and then calls:

```objc
[abProperties resetConfigHashToEmptyString];
[manager requestFreshABProps:NO withCompletion:completion];
```

The three-parameter native variant is also captured for manager discovery/diagnostics:

```objc
-[XMPPConnectionABPropsRequestManager
    requestFreshABPropsWithGroupJID:
    deltaUpdate:
    completion:]
```

A heuristic `fetch`/`sync`/`refresh` lookalike is no longer reported as success.
Dispatch is also not success: the transaction is confirmed only when native
completion fires and the same account-scoped `WAProperties` object has a
non-empty hash again.

Expected log markers:

```text
[ABProps][ABTForceFull] token=... reset confirmed, exact request dispatched via ...
[ABProps][ABTForceFull] token=... outcome=verified_native_completion_hash_refilled hashRefilled=YES ...
```

There is no `XMPPRequestABProperties` constructor hook in this flow.

If the native retry pipeline exceeds 45 seconds, the result is a terminal
timeout rather than success. WATweaks ends its correlation and releases the
process-wide ABT gate; a late native completion is forwarded to WhatsApp but
cannot overwrite that result or block a later explicit transaction.

## 2. Canonical ABProp names from native getter descriptors

The old name path depended on external files such as `id_name_mapping.json`/`params_map*` and otherwise displayed `ABProperty N`.

The current build exposes canonical no-argument ABProp getters whose implementations use the validated ARM64 shape:

```asm
adrp x2, <descriptor-page>
add  x2, x2, <descriptor-offset>
b    <generic typed ABProp accessor>
```

The descriptor points to the decimal wire-code string. dogfood2 now builds `code -> selector` directly from app-owned Objective-C getter implementations at runtime, with Mach-O address validation before dereferencing descriptor/string storage. External name files remain fallback-only.

For the analyzed build, the static extraction produced 8,693 unique code/name pairs. Representative expected resolutions include:

```text
1777  is_meta_employee_or_internal_tester
2945  is_internal_tester
9660  ios_internal_rage_shake_enabled
22652 rage_shake_eligible_via_bug_form
23336 waios_mc_debug_ui_enabled
33156 show_fishfooding_toggle_in_bug_reporting_form
26311 bug_reporting_attach_pathfinder_pre_bug_creation
24850 bug_reporting_abprops_uploaded_on_submissoin
```

Expected log marker:

```text
[ABProps][NamesV2] native map=<count> appClasses=<count> noArgMethods=<count>
```

On this exact build, `<count>` should approach the statically validated 8,693 unique mappings; a lower count should be treated as a runtime/image-loading diagnostic rather than silently relabeling entries.

## 3. Deterministic FBMobileConfigContextManager resolution

The prior bridge depended on graph traversal/capture after an account-scoped manager happened to cross one of the hooked methods. v2 keeps that path but adds deterministic class-level candidates:

```objc
+[FBMobileConfigContextManager sessionlessContextManager]
+[FBMobileConfigContextManager defaultValueContextManager]
```

Candidates are accepted only after validation with the available native checks:

```objc
-hasValidManager
-hasValidConfig
-getStableIdFromParamSpecifier:
```

Capture hooks are also requested at startup and again as dyld images are loaded, instead of waiting for the ABProps/MC screen to be opened.

The resolved crosswalk remains:

```text
ABProp / WA stable ID
  -> WAMCEvaluation.getMCSpecifierForStableId:
  -> paramSpecifier
  -> local_config_index + parameter_index + compact token
  -> FBMobileConfigContextManager.getStableIdFromParamSpecifier:
  -> external_config_stable_id
  -> id_name_mapping.json names when present
```

Expected log marker when a deterministic fallback is used:

```text
[MobileConfig][ResolverV2] using +sessionlessContextManager -> FBMobileConfigContextManager
```

(or `+defaultValueContextManager` if that is the usable manager in the running state).

## 4. Export semantics

The low 16 bits of the translated paramSpecifier are no longer exposed as `parameter_stable_id`. That label implied an external schema identity that the field does not represent.

v2 exports:

```json
{
  "compact_parameter_token": 21,
  "external_config_stable_id": 123456,
  "config_name": "...",
  "parameter_name": "..."
}
```

`external_config_stable_id`, `config_name`, and `parameter_name` are emitted only when the live MobileConfig manager/schema resolves them.

The native snapshot document identifies itself as:

```text
WATweaks WhatsApp native ABProps snapshot v2
```

and includes a `mobileconfig_resolution` section so an unresolved manager cannot be mistaken for a successful final admin/config-ID crosswalk.
