# WhatsApp 26.40 Native Alignment Specification

## Evidence boundary

The implementation is aligned to the supplied decrypted WhatsApp 26.40.10
build 1086609742 IPA. Facebook archives are excluded. Repository code and
historical names are not evidence of native availability.

Static analysis established these contracts:

- ABProps uses XMPP ABT. `requestFreshABProps:withCompletion:` has ABI
  `v28@0:8B16@?20`; its completion is `(success, didChange, configKey)`.
- ABT full requests use `configHash`; delta requests use `refreshID`, defaulting
  to string `"0"` when absent.
- MobileConfig account fetch uses `fetchMobileConfig:stack:` with ABI
  `v24@0:8B16i20`; the native automatic call is `NO, -1`.
- MobileConfig may route through XWA2 or WWW. Authenticated WWW requires the
  canonical user credential feature `mobile_config`; sessionless WWW requires
  `WAGraphQLStaticAuthTokens.staticAT`.
- `one_query_hash`, `one_query_string`, BLN fields, `global_value_hash`, and
  `ep_refresh_id` are MobileConfig request data, not ABProps data.
- A MobileConfig fetch is governed by a native FetchPlan and can complete as
  empty/no-change; installed data and source-of-truth selection are separate.
- `id_name_mapping.json`, `qe_info.json`, and `mc_overrides.json` are native
  MobileConfig repository artifacts. No independent mapping download endpoint
  is proven.
- `mc_overrides.json` is owned by the C++ `FBMobileConfigOverridesTable`.
  WATweaks must not write it directly. Local supported overrides continue
  through `FBMobileConfigStartupConfigs` with persistent readback.
- `isInternalUser` is server/account identity (`adm`) gated by
  `serverPropsDisableExperimental`; MobileConfig internal request options are
  not employee eligibility.
- `DebugMenuProvider`, `WADebugViewController`, and
  `PrivateExperimentationDebugViewController` are absent from all 17 Mach-O
  images. The verified Settings dogfood action opens
  `https://fburl.com/df_iphone` for setting type 140.
- The main app bundle contains nine inspectable Mach-O images; all 17 include
  extension-process executables. A browser in the main process must label that
  boundary and must not load dormant modules solely for inspection.
- Real WAAB code families are Objective-C category owners. Selector-token
  grouping is a fallback, not authoritative family metadata.

## Required behavior

1. Native fetch dispatch must never depend on diagnostic observer installation.
   Observer failure is reported as reduced observability, not as a refusal to
   call WhatsApp's native request.
2. ABProps and MobileConfig remain separate actions, state machines, validators,
   and result documents.
3. MobileConfig diagnostics distinguish dispatch, FetchPlan/no network, XWA2 or
   WWW observation, auth prerequisites, query-hash fallback/error, native success
   marker, file persistence, and effective source-of-truth.
4. The runtime UI exposes every inspectable main-process image in one image hub.
   Inventory work is asynchronous, cached by dyld generation, and never repeated
   synchronously for each shortcut.
5. Runtime family labels prefer a build catalog extracted from the supplied IPA;
   heuristic labels are visibly marked as fallback.
6. Obsolete debug-controller launch paths are not presented as available.
   Dogfooding uses the verified URL action. Internal/employee state is diagnostic
   and is never locally forged.
7. Psiphon remains visible in image inventory. No MobileConfig/ABProps role is
   attributed to it without runtime evidence.
8. Static analysis and host tests may prove ABI selection, dispatch policy,
   catalog behavior, and UI inventory behavior. They must not claim live server,
   device, account eligibility, or successful download.
