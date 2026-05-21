# WATweaks — Gating & Feature-Flag Dump

Static-analysis dump from the WhatsApp 26.19.10 beta IPA, including the main
binary (`WhatsApp`, 138 MB) and `SharedModules.framework/SharedModules` (67 MB).
This file is meant as the source-of-truth reference for which class owns
which gating selector, which selectors are real, and which ones existed only
as call sites without an Objective-C implementation in this build.

## How the analysis was done

For each gating selector we cared about, we walked three Mach-O sections of
both binaries: `__objc_classlist` (registered ObjC classes), `__objc_methlist`
(declared methods on each class), and `__objc_catlist` (categories that
attach methods to a class at dyld-load time). A selector was considered
"owned" by a class only if it appeared in that class's method list or in a
category whose target was that class. Selectors that appeared only in
`__objc_methname` (the global selector name pool) but on no class are call
sites with no Objective-C implementation in this build — they are typically
Swift-only methods.

## Native developer menu — primary surface

The user-facing developer menu UI lives in `WADebugViewController` (the real
class — see screenshot at 01:31 showing 93 methods, 29 ivars).

`WADebugViewController` accepts a `WAContextMain` instance via these
initializers, both confirmed in the binary:

- `-initWithUserContext:` — simplest, single-argument form
- `-initAsModalWithUserContext:` — same arg, sets up as modal

It is added to the `childViewControllers` of `WASettingsNavigationController`
during launch. The gates `isDebugMenuAllowed` and `isDebugMenuShortcutEnabled`
only control whether WhatsApp's own navigation logic surfaces the entry; the
controller itself exists regardless. This is why `WAGRDebugMenuLauncher.xm`
bypasses the gates entirely and instantiates `WADebugViewController` directly.

`WADebugViewController` has these notable section-builder methods (subset
from the 93 total, useful for future granular toggles):

```
addPartnerBillingSection
addYouthScreens
addBrazilO13Section
addPrivacySettingsComparisonSection
addRegistrationSectionWith:isMCCEuropean:mccFromRaw:
clearAllBizProfiles / clearAllBizInfo / clearAllBizCertificates
makeAvatarsDebugViewControllerWithDisableStickerAnimation:
addCustomURLFromBizProfileRowWithSection:
```

The "Pinned sections" and "Starred items" features inside the dev menu use
ivars `_allPinnedSectionsNames` and `_allStarredItems` (NSMutableSet).

## Gate-selector ownership map

Each row lists the selector, its confirmed owner class (or "Swift-only" if
no ObjC owner was found), and the binary where it lives.

| Selector | Owner | Binary | Notes |
|---|---|---|---|
| `-isDebugMenuAllowed` | `_TtC15WADebugMenuMain17DebugMenuProvider` | WhatsApp | Added by category `WADebugMenuMain`. Hooked in `WAGRNativeDevMenuHooks.xm`. |
| `-isDebugMenuShortcutEnabled` | `_TtC15WADebugMenuMain17DebugMenuProvider` | WhatsApp | Same category. Hooked in `WAGRNativeDevMenuHooks.xm`. |
| `+isInternalUser` | `WAServerProperties` | SharedModules | Class method. Hooked in `WAGREmployeeHooks.xm`. |
| `-isVerifiedChannelFeatureFlagEnabled` | `WAContextMain` | WhatsApp | Added by category `WADependencyProviderMain3`. Hooked in `WAGRContextHooks.xm`. |
| `-isBlueSubscriptionActive` | `WAContextMain` | WhatsApp | Same category. Not currently hooked. |
| `-verifiedChannelFeatureFlagLimit` | `WAContextMain` | WhatsApp | Same category. Returns int — would need different trampoline shape if hooked. |
| `-isDebugBuild` | Swift-only on this build | n/a | Appears in selref but no ObjC owner found. |
| `-isDebugOverlayEnabled` | Swift-only on this build | n/a | Appears in selref. Likely controls a runtime debug overlay HUD. |
| `-isDebugUsyncMonitorEnabled` | Swift-only on this build | n/a | Sync monitor overlay. |
| `-isInternalOnly` | Swift-only on this build | n/a | Wide internal gate. Often used in if-statements that wrap experimental UI. |
| `-isInternalGroup` | Swift-only on this build | n/a | Probably gates group-specific internal features. |
| `-isInternalMetaAINavigation` | Swift-only on this build | n/a | Meta AI internal nav. |
| `-isInternalEmergencyRecoveryScreen` | Swift-only on this build | n/a | Internal recovery flow. |
| `-isMetaEmployeeOrInternalTester` | Swift-only on this build | n/a | Trampoline kept in `WAGREmployeeHooks.xm` for forward-compat. |
| `-is_meta_employee_or_internal_tester` | Swift-only on this build | n/a | Snake-case sibling. Same status. |
| `-graphQLEmployeeC1Disabled` | Swift-only on this build | n/a | Inverted-polarity gate. |

The Swift-only gates can still be intercepted, but require either:

1. Reading `WAAuraGating.GatedSubscriptionProvider` and similar Swift gating
   classes' generated thunks (which Objective-C runtime introspection can
   sometimes reach), or
2. Hooking the callers (the methods that branch on these gates) instead of
   the gates themselves. This is more brittle but covers Swift sites.

## Gating classes discovered

The static scan turned up a large family of gating classes in the WhatsApp
binary. Each one is a candidate for a future hook target.

ObjC-named gating classes (in `__objc_classlist`):

- `FBCCGatingGestureRecognizer`, `FBCCGestureGatingController` — gesture
  gating from the Bloks framework
- `BKSignalsGatingMemoizedResult` — Bloks signals gating cache

Swift-mangled gating classes (`_TtC[N]...Gating[...]`):

- `_TtC13WAVaultGating19VaultGatingProvider` — backup/vault gating
- `_TtC20WAPaidFeaturesGating21SMBFeatureFlagStorage` — paid features
- `_TtC20WAPaidFeaturesGating26PaidFeaturesAppGroupWriter`
- `_TtC20WASubscriptionGating31SubscriptionDeviceConfigStorage`
- `_TtC23WASubscriptionAgeGating26SubscriptionAgeGatingCache`
- `_TtC23WASubscriptionAgeGating28SubscriptionAgeGatingManager`

User-screenshot-confirmed Swift gating classes:

- `WAAuraGating.GatedSubscriptionProvider` (with ivars `wrappedProvider`,
  `abProperties`, `notificationCenter`, `isSimulationMode`)
- `WAUsernameGatingService` (referenced in `WAContextMain.usernameGatingService`)

## FBMobileConfig — the actual feature-flag store

The runtime browser screenshot of `FBMobileConfigAdminIDContextManager`
showed the full MobileConfig system Anthropic-side, including an
`shared_ptr<FBMobileConfigOverridesTable> overrides` field that holds the
overrides table. The bound classes are `FBMobileConfigStartupConfigs` and
`FBMobileConfigStartupConfigsDeprecated`. Hooking into this layer is a
strictly better long-term plan than hooking individual gates, because it
sits below all the per-feature gating classes — every gate ultimately reads
from this overrides table. This is a target for a future iteration.

## WAContextMain — dependency container

The runtime browser showed `WAContextMain` exposes 124 properties, including:

- `WAUsernameGatingService *usernameGatingService`
- `<WAAIIncognitoManagerProtocol> *aiIncognitoManager`
- `_TtC17WAMessagePrefetch19WAMessagePrefetcher *messagePrefetcher`
- `WAGroupHistoryBundleService *groupHistoryBundleService`
- `_TtC15WAPMAOnboarding20SponsorAccountLinker *sponsorAccountLinker`
- `_TtC28WAContactInfoViewControllers37BizProfileGetShimmedURLGraphQLFetcher *bizProfileFetcher`
- `WAUsernameService<...> *usernameService`
- `WAPTTTranscriptionManagerMain *pttTranscriptionManager`
- `<_TtP13WAAIThreading25AIThreadManagerObjCBridge_> *aiThreadManagerObjC`

This means `WAContextMain` is the de-facto application-wide service locator.
Any feature whose gate or implementation is reachable via one of these
properties can be intercepted by hooking the property accessor and replacing
the returned object with a stub or wrapper.

## Tweak ecosystem on this device

The IPA shipped with several other tweaks already injected, which is useful
for cross-referencing approaches:

- `Watusi.dylib` (2.7 MB) — full-featured hidden-settings tweak. Uses Logos
  hooks. Notable selectors: `settingsTableRowFromCell:`, `wHideSettings`,
  `wHideWhatsAppWeb`, `wHiddenChatsChatListAccess`. The `settingsTableRowFromCell:`
  pattern is the entry point for unhiding settings rows.
- `libWatusiToolsSL.dylib` (8.5 MB) — Watusi sideload helper.
- `WALiquidGlass.dylib` (175 KB) — LiquidGlass feature override.
- `Stalky.dylib` (862 KB) — online status tracker.
- `OnlineNotify.dylib` (228 KB), `OnlineAdsBlock.dylib` (138 KB).
- `BlockWAUpdates.dylib` (97 KB), `ContactSync.dylib` (248 KB).
- `Watusi.bundle/FLEX.framework/FLEX` (3 MB) — full FLEX runtime browser,
  already on disk. Future iteration can `dlopen` this and call
  `[FLEXManager.sharedManager showExplorer]` to launch it without bundling
  our own copy.

## What is left for next iterations

1. Hook the FBMobileConfig overrides table for a single-point-of-control
   gating system that covers Swift gates too.
2. Replace each `WAContextMain` property accessor that returns a gating
   service with a wrapped one whose decisions we control.
3. `dlopen` the bundled FLEX framework and add a "FLEX Browser" button to
   the WATweaks menu — saves us from bundling our own copy.
4. Hook `settingsTableRowFromCell:` (Watusi's pattern) to reveal hidden
   rows inside Settings without instantiating the dev menu.
5. Granular per-section toggles for `WADebugViewController` (the 93 methods
   list above gives the menu structure).


## WATweaks unified-gater pass

- Liquid Glass menu is now WAAB-first with WDSLiquidGlass aliases written by the same toggle, avoiding duplicate WAAB/WDS switches.
- Added Evolve / About Me category from WhatsApp main + SharedModules strings: evolve_about_m1*, contact card thought bubble, contact/profile UI refresh, profile badges, and profile-photo privacy gates.
- Linked / Primary / Companion icon changed to a stable SF Symbol and root menu adds fallback icons.
