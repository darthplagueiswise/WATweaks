# WhatsApp ABProps -> FBMobileConfig descriptor analysis

This note records only findings that were directly validated from the supplied WhatsApp iOS binaries and runtime exports. It deliberately separates proven structure from unresolved fields.

## Runtime context

The live account context resolves:

```text
WAContextMain.mobileConfig
 -> FBMobileConfigUserSessionContextManager
```

`getOverridesTablePath` on that manager resolves the account-scoped MobileConfig directory. The adjacent `id_name_mapping.json` pathname is only an expected local path; its presence does not imply that WATweaks or WhatsApp downloaded that JSON as a standalone server artifact.

## WAMCEvaluation translation

For a WA/ABProp stable ID, `+[WAMCEvaluation getMCSpecifierForStableId:]` returns the packed specifier used by MobileConfig.

Example:

```text
WA stable ID              1777 / 0x6f1
paramSpecifier             0x008102f700000227
localConfigIndex           759 / 0x2f7
parameterIndex             0
compact parameter token    551 / 0x227
native type                bool
```

The low 16-bit token is compact translation metadata. It is not the mc_overrides parameter row index and must not be named `parameter_stable_id`.

## `getStableIdFromParamSpecifier:` disassembly

On the analyzed SharedModules Mach-O the method decodes the specifier and calls an internal helper with `localConfigIndex` and `parameterIndex`:

```asm
ubfx x21, x20, #0x20, #0x10   ; localConfigIndex
lsr  w20, w20, #0x10          ; parameterIndex
...
mov  x1, x21
mov  x2, x20
bl   <translation helper>
```

The helper performs:

```asm
ldr    w22, [x9, x8, lsl #2]  ; localConfigIndex -> internal slot
...
mov    w9, #0x18
umaddl x9, w22, w9, x8         ; descriptor = base + slot * 0x18
ldp    x8, x9, [x9]            ; begin/end of parameter records
...
ldr    w10, [x8, #0x38]
cmp    w10, w20                 ; compare parameterIndex
...
add    x8, x8, #0x50           ; next parameter record
...
ldr    w0, [x8, #0x4c]         ; validity/presence field
cbz    w0, <fail>
ldr    w20, [x8, #0x30]        ; stable ID returned by the helper
```

Proven structure:

```text
config descriptor stride      0x18
parameter-record stride       0x50
parameter record +0x38        parameterIndex comparison field
parameter record +0x4c        validity/presence field
parameter record +0x30        value returned by getStableIdFromParamSpecifier:
```

The third qword of the `0x18` config descriptor (`descriptor+0x10`) is not yet assigned a semantic name. Do not label it as admin/config ID until a consumer proves that interpretation.

## Runtime crosswalk result

The exported live crosswalk translated 16,932 WA stable IDs. `getStableIdFromParamSpecifier:` produced 16,907 non-zero results. In that export every non-zero result matched the original WA stable ID; there were no non-zero mismatches.

For example:

```text
WA stable ID 1777
  -> specifier 0x008102f700000227
  -> localConfigIndex 759
  -> parameterIndex 0
  -> getStableIdFromParamSpecifier: 1777
```

Therefore the method is a stable-ID round trip for the observed ABProp domain. The implementation must not derive another ID by treating `localConfigIndex` or the low-16 compact token as an external stable ID.

## `_kMobileConfigAdminId` table correlation

The supplied params-map representation associates the same record with:

```text
*,-1,6f1
,,,227
```

For the analyzed schema, record/local index 759 corresponds to admin/stable value `0x6f1 = 1777`, parameter position 0 and compact token `0x227`.

This correlation is why the runtime result `1777` must not be rewritten as `759` or `551`. The remaining reverse-engineering task is to follow the native translation-table consumers (`FBMobileConfigStableSpecifierTranslationTable`, `stableIdSpecToSlotId_`, `configKeyToLocalIndex_`, and `FBMobileConfigAdminIDContextManager`) and assign exact names to the config descriptor fields, especially `+0x10`.

## Source rules for dogfood2

1. Never derive an mc_overrides identity from `localConfigIndex`.
2. Never call the low 16 bits of the specifier a stable ID.
3. Preserve the raw result of `getStableIdFromParamSpecifier:` separately from translation metadata.
4. `id_name_mapping.json` is optional name enrichment; lack of names must not invalidate the numeric mapping.
5. Do not report an ID as a different external/admin ID unless the binary path that performs that translation has been proven.
6. Prefer the live `FBMobileConfigUserSessionContextManager` exposed by `WAContextMain.mobileConfig` for account-scoped reads.

## Still to prove from disassembly

- exact meaning of config descriptor `+0x10`;
- construction and lookup semantics of `stableIdSpecToSlotId_`;
- construction and lookup semantics of `configKeyToLocalIndex_`;
- exact responsibilities of `FBMobileConfigAdminIDContextManager` relative to the base/UserSession context manager;
- whether any separate stable-ID namespace exists for configs not represented by the ABProp/WAMCEvaluation domain.

Until those consumers are traced, source code and diagnostics should use names that describe the observed operation rather than inventing an unproven namespace conversion.
