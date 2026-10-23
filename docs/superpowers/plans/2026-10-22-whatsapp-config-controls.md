# WhatsApp Configuration Controls Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one fresh whole-change reviewer at the end. Steps use checkbox syntax.

**Goal:** Update existing editors and add IPA-backed, reversible configuration toggles.

**Architecture:** Extend the existing ABProps browser with inclusion, display-title and three-state hooks. A curated subclass supplies verified selector groups and an explicit backend chooser. The common runtime mutation API supplies truthful outcomes to every editor; native overrides keep the existing verified writer.

**Tech Stack:** Objective-C/UIKit, C policy/catalog headers, Python unittest, Theos.

**Spec:** `docs/superpowers/specs/2026-10-22-whatsapp-config-controls.md`

## Global Constraints

- WhatsApp 26.40.10 (1086609742), arm64, minimum iOS 15.
- Facebook inputs are excluded; no invented authentication, hashes or eligibility.
- Preserve native MC/ABT dispatch and current native span mapping.
- No direct mc_overrides.json writer, no implicit backend fallback.
- Native/OFF/ON distinguish absence from persisted false; unknown is not false.
- Use the existing isolated branch/PR. Publishing there is already authorized.

## Review Focus

- Protected/rejected mutation must never be called saved/pending.
- Reset must not forget native override tracking before attempting removal.
- Switching backends must not silently stack overrides for the same parameter.
- Refresh/failed writes must restore the control from stored state.
- Absent selectors, other builds and unreadable values must not become false toggles.

### Task 1: Truthful mutation outcomes in existing editors

**Files:** `src/Runtime/WAGRRuntimeValueStore.{h,m}`, new `src/Runtime/WAGRConfigControlPolicy.h`, `src/Menu/WAGRRuntimeValueEditor.m`, `src/Menu/WAGRABPropsBrowserVC.{h,m}`, new `scripts/wagr_test_config_controls.py` and fixture.

**Interfaces:** Produce `WAGRRuntimeValueCanOverrideTarget(class,selector)`, `WAGRRuntimeValueTrySetOverride(class,selector,meta,type,value)` returning rejected/pending/installed, and browser hooks `wagrIncludesRuntimeEntry:`, `wagrDisplayTitleForEntry:`, `wagrUsesThreeStateControls`, public `scanNow`.

- [ ] Write failing portable tests for persisted=false outcomes, 0/false/true selection and backend conflict/removal; integration guards reject old editor paths that claim pending without persistence.
- [ ] Run `python3 scripts/wagr_test_config_controls.py`; expect named missing-implementation failures.
- [ ] Implement policy and common mutation API; update generic editor/browser failure paths, protected target presentation, three-state removal and conflict checks.
- [ ] Run the focused tests and full `for t in scripts/wagr_test_*.py scripts/wagr_validate_*.py; do python3 "$t" || exit 1; done`; expect all PASS. Commit.

### Task 2: Curated IPA-backed control groups and menu integration

**Files:** new `src/Runtime/WAGRConfigControlCatalog.h`, new `src/Menu/WAGRConfigControlsVC.{h,m}`, `src/Menu/WAGRMainSettingsVC.m`, `src/Menu/WAGRFeatureBundlesVC.m`, `scripts/wagr_test_config_controls.py`.

**Interfaces:** Consume Task 1 browser hooks. Produce `WAGRConfigControlsVC initWithUserContext:group:`, catalog group and descriptor lookup functions; descriptor fields are selector/title/type/image/category.

- [ ] Write tests for required MC/rollout/WWW/dogfood/internal getters, exact IPA category/image membership, supported-build gating and menu reachability. Expect FAIL before implementation.
- [ ] Add only IPA-confirmed descriptors; subclass filters entries before enrichment, displays friendly labels, Native/OFF/ON and explicit Local/MC backend. Keep availability and unknown values honest.
- [ ] Add menu links for all groups and links from semantic feature families; resolve account objects on the main thread before scanning metadata on the worker.
- [ ] Run focused and full host checks; expect all PASS. Commit.

### Task 3: Visible fetch actions, safe reset and delivery

**Files:** `src/Menu/WAGRMobileConfigExportVC.m`, `src/Menu/WAGRABPropsABTLabVC.m`, `src/Menu/WAGRMainSettingsVC.m`, tests, `Makefile`, current report and README.

**Interfaces:** Consume common stores and native `WAGRABPropsNativeClearTrackedOverrides(context,diagnostic)`. Preserve native fetch completion/account/artifact APIs.

- [ ] Write failing guards for visible fetch, UI-busy serialization, no stale mappings after failed rescans and reset tracking retained on failure.
- [ ] Add visible fetch action, keep export menu focused on exports and never launch a rescan/overwrite busy states during fetch. Remove stale 'next checkpoint MC' wording. Reset native overrides first; on failure retain registry and show the result.
- [ ] Run all host checks, diff/shell checks; add the new regression suite to before-all. Update docs with actual controls and limits. Commit.
- [ ] Obtain one fresh review of the full change. Fix important findings with RED→GREEN checks; publish exact validated tree to the existing PR and verify macOS/Theos CI.
