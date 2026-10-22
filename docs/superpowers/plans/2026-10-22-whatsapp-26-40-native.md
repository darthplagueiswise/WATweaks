# WhatsApp 26.40 Native Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align WATweaks fetch, runtime inventory, experiment-family, and dogfood behavior with the supplied WhatsApp 26.40.10 IPA.

**Architecture:** Keep ABT and MobileConfig as independent native pipelines and make instrumentation passive. Replace repeated whole-runtime scans with a cached image snapshot and use a build metadata catalog for WAAB family ownership, falling back explicitly when unavailable.

**Tech Stack:** Objective-C/Logos, Objective-C runtime and dyld APIs, Python unittest validators, Theos build.

**Spec:** `docs/superpowers/specs/2026-10-22-whatsapp-26-40-native.md`

## Global Constraints

- The supplied WhatsApp IPA is the native source of truth; Facebook inputs are excluded.
- Never synthesize credentials, eligibility, query hashes, unit IDs, or server responses.
- Never write `mc_overrides.json` directly or call the C++ shared-pointer setter through `objc_msgSend`.
- Do not load dormant frameworks solely to inspect them.
- Do not claim device/server success from static tests.
- Every behavior change follows RED-GREEN TDD.

## Review Focus

- Missing diagnostic hook must still dispatch the exact native fetch.
- WWW routing must not be reported as an XWA2 failure.
- Repeated image-hub navigation must not rescan the full runtime on the main thread.
- Dormant images and extension-process images must not be conflated with loaded images.
- Missing build-family metadata must degrade to a marked fallback without hiding selectors.

---

### Task 1: Passive ABProps and MobileConfig instrumentation

**Files:**
- Modify: `scripts/wagr_test_mobileconfig_fetch.py`
- Modify: `scripts/wagr_validate_abprops_fetch.py`
- Modify: `src/Runtime/WAGRMobileConfigNativeEngine.m`
- Modify: `src/Runtime/WAGRABPropsABTLiveService.m`

**Interfaces:**
- Consumes: verified ABT and `WAChatManager` ABIs from the spec.
- Produces: native dispatch paths whose return value is independent of observer installation; diagnostic fields describing installed observers.

- [ ] Add failing tests proving missing observers do not block native ABT or MC dispatch and XWA2 is not mandatory when WWW observation exists.
- [ ] Run `python3 scripts/wagr_test_mobileconfig_fetch.py && python3 scripts/wagr_validate_abprops_fetch.py`; expect failures naming mandatory observer gates.
- [ ] Make observer installation best-effort while preserving exact ABI checks and request arguments.
- [ ] Re-run the focused command; expect PASS. Then run `for t in scripts/wagr_test_*.py scripts/wagr_validate_*.py; do python3 "$t" || exit 1; done`; expect all PASS. Commit as `fix: make native fetch observers passive`.

### Task 2: MobileConfig stage and protocol diagnostics

**Files:**
- Modify: `scripts/wagr_test_mobileconfig_fetch.py`
- Modify: `src/Runtime/WAGRABPropsReleaseNativeLinkage.m`
- Modify: `src/Runtime/WAGRMobileConfigNativeEngine.m`
- Modify: `src/Runtime/WAGRMobileConfigNativeEngine.h`

**Interfaces:**
- Consumes: passive observer state from Task 1.
- Produces: a fetch-state document separating auth/route/input, query fields, network observation, success marker, persistence, and timeout stage.

- [ ] Add failing tests for WWW/XWA2 route classification, one-query/BLN input capture, and precise timeout stage naming.
- [ ] Run `python3 scripts/wagr_test_mobileconfig_fetch.py`; expect failures for missing WWW/query-stage fields.
- [ ] Extend passive input snapshots and state classification without constructing native inputs.
- [ ] Re-run the focused test and complete host suite; expect PASS. Commit as `feat: report native mobileconfig fetch stages`.

### Task 3: Complete and bounded runtime image browser

**Files:**
- Modify: `scripts/wagr_validate_runtime_browser.py`
- Modify: `src/Runtime/WAGRSurface.h`
- Modify: `src/Runtime/WAGRSurface.m`
- Modify: `src/Menu/WAGRMainSettingsVC.m`
- Modify: `src/Menu/WAGRRuntimeGatesVC.m`
- Modify: `src/Menu/WAGRSurfaceListVC.m`
- Remove: `src/Runtime/WAGRRuntimeSurfaceCompatibility.xm`
- Modify: `Makefile`

**Interfaces:**
- Consumes: dyld and bundled-path safety policy.
- Produces: one cached asynchronous image hub covering all main-process images; family scans operate from one class snapshot and autorelease pools.

- [ ] Add failing behavioral validators for nine supplied-IPA image fixtures, no synchronous `allSurfaces` shortcut scan, no alias hook, cache invalidation by dyld count, and explicit extension boundary.
- [ ] Run `python3 scripts/wagr_validate_runtime_browser.py`; expect failures identifying fixed shortcuts, aliases, or uncached scans.
- [ ] Implement the image hub/cache and bounded background scans; remove legacy aliases.
- [ ] Re-run the runtime validator and complete host suite; expect PASS. Commit as `fix: expose cached complete runtime image inventory`.

### Task 4: IPA family catalog and verified dogfood/internal surfaces

**Files:**
- Create: `resources/waab_family_catalog_26_40_10.json`
- Create: `src/Runtime/WAGRWAABFamilyCatalog.h`
- Create: `src/Runtime/WAGRWAABFamilyCatalog.m`
- Modify: `scripts/wagr_validate_runtime_browser.py`
- Modify: `scripts/wagr_validate_sources.py`
- Modify: `src/Runtime/WAGRSurface.m`
- Modify: `src/Runtime/WAGRABPropsRuntime.m`
- Modify: `src/Menu/WAGRMainSettingsVC.m`
- Modify: `src/Hooks/WAGRDebugMenuLauncher.xm`
- Modify: `Makefile`

**Interfaces:**
- Consumes: selector-to-category metadata extracted from WhatsApp and SharedModules.
- Produces: authoritative build catalog lookup with marked fallback; a verified dogfood URL action and read-only internal identity diagnostics.

- [ ] Add failing tests for known category mappings, fallback marking, absence-aware launcher behavior, and the exact dogfood URL.
- [ ] Run `python3 scripts/wagr_validate_runtime_browser.py && python3 scripts/wagr_validate_sources.py`; expect failures for heuristic-only family ownership and obsolete launchers.
- [ ] Add the compact family catalog and route family lookups through it; replace unavailable launcher presentation with verified behavior and diagnostics.
- [ ] Re-run the focused validators and complete host suite; expect PASS. Commit as `feat: align WAAB families and dogfood launcher with IPA`.

### Task 5: Documentation, evidence reconciliation, and final verification

**Files:**
- Modify: `docs/WHATSAPP_26_40_UPDATE_PTBR.md`
- Modify: `README.md` only if navigation text is stale.

**Interfaces:**
- Consumes: Tasks 1-4 result schemas and verified test output.
- Produces: accurate Portuguese documentation separating confirmed static behavior from device/server unknowns.

- [ ] Update the document with the four native pipelines, auth/FetchPlan/query-hash behavior, local artifact/override layers, family metadata, launcher compatibility, Psiphon boundary, and remaining unknowns.
- [ ] Run every host test/validator, a clean Theos build when the toolchain is available, and `git diff --check`.
- [ ] Commit documentation and verification adjustments as `docs: document WhatsApp 26.40 native pipelines`.
- [ ] Package the whole-branch review and obtain an independent review before finishing.
