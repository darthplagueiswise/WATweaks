# WATweaks runtime inventory pass

Generated from uploaded `SharedModules(11)` and `WhatsApp(4)`. This is the inventory-first pass required before exact JSON backup/import.

## WAABProperties

AB/private experimentation wrapper layer; direct WAABProperties has no ObjC methods in static metadata, so the hookable static surface is boolForKey/stringForKey providers and runtime subclasses.

Static classes matched: 16 · included in manifest: 16

- `SharedModules` `WAABPropertiesPreChatd` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAGroupABProperties` — props=0 ivars=7 methods=5 boolLike=0
- `SharedModules` `XMPPRequestABProperties` — props=1 ivars=1 methods=0 boolLike=0
- `SharedModules` `WAABProperties` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `FOAWAABPropertiesImpl` — props=0 ivars=1 methods=7 boolLike=1
  - bool-like: `boolForKey:defaultValue:`
- `WhatsApp` `_TtC7Avatars24AvatarCachedABProperties` — props=1 ivars=1 methods=2 boolLike=1
  - bool-like: `isCanonicalEntEnabled`
- `WhatsApp` `WAChatStorageABPropertiesUpdateWorker` — props=4 ivars=1 methods=0 boolLike=0
- `WhatsApp` `_TtC15WADebugMenuBase38WADebugABPropertiesOverridesQRCodeView` — props=0 ivars=4 methods=4 boolLike=0
- `WhatsApp` `WAAICallSettingsABProperties` — props=0 ivars=0 methods=4 boolLike=3
  - bool-like: `isAICallScreenSharingEnabled`, `isSMBAICallEnabled`, `isAICallMessageCellEnabled`
- `WhatsApp` `WAAIInteractionsABProperties` — props=0 ivars=0 methods=1 boolLike=1
  - bool-like: `isStandaloneAIVoiceModeEnabled`
- `WhatsApp` `WAStatusArchiveABProperties` — props=4 ivars=2 methods=3 boolLike=2
  - bool-like: `isArchiveOnDiskAllowed`, `isAutoArchiveEnabled`
- `WhatsApp` `WAStatusMediaLayoutABProperties` — props=0 ivars=0 methods=2 boolLike=1
  - bool-like: `isTextStatusLayoutsEnabled`

## WAContext+WAContextMain

WAContext is the abstract/container surface in SharedModules; WAContextMain is the concrete app object graph in the main executable. Treat WAContext as gates/providers and WAContextMain as dependency graph/services.

Static classes matched: 45 · included in manifest: 45

- `SharedModules` `WAContextDependencyInversionShared` — props=0 ivars=1 methods=2 boolLike=0
- `SharedModules` `WAContextualRowUserFlow` — props=0 ivars=0 methods=5 boolLike=0
- `SharedModules` `WAContext` — props=4 ivars=6 methods=0 boolLike=0
- `SharedModules` `WAContextObjectProvider` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAContextDependencyInversion` — props=0 ivars=1 methods=2 boolLike=0
- `SharedModules` `WAContextDependencyInversionNoop` — props=0 ivars=1 methods=2 boolLike=0
- `SharedModules` `WAPBCTWAContextDetails` — props=32 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAPBCTWAContext` — props=50 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAPBCTWAContextAdId` — props=4 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAContextDelegateImpl` — props=0 ivars=1 methods=0 boolLike=0
- `SharedModules` `WAContextMenuController` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAContextWrapper` — props=0 ivars=1 methods=2 boolLike=0

## WAServerProperties

Class-method based server/account property owner. isInternalUser is a master internal/dogfood gate fed by userContext / WAContext.

Static classes matched: 1 · included in manifest: 1

- `SharedModules` `WAServerProperties` — props=0 ivars=0 methods=29 boolLike=7
  - bool-like: `isInternalUser`, `isReadReceiptsEnabledForDate:`, `paymentsUPIOverdraftAccountEnabled`, `listMessageReceptionDisabled`, `isEphemeralMessagesSupportedDurationFor:hourOptions:`, `isAfterReadSupportedDuration:`, `frequentlyForwardedGroupSettingEnabled`

## WAMobileConfig

Fetch/cache/GraphQL/gating bridge. This is the upstream experiment source, not just a UI menu target.

Static classes matched: 47 · included in manifest: 47

- `SharedModules` `WamEventMobileConfigConsistencyStats` — props=13 ivars=13 methods=0 boolLike=0
- `SharedModules` `WamEventMobileConfigDebugEvent` — props=3 ivars=3 methods=0 boolLike=0
- `SharedModules` `WamEventMobileConfigErrors` — props=3 ivars=3 methods=0 boolLike=0
- `SharedModules` `WamEventMobileConfigExposureDataValidation` — props=3 ivars=3 methods=0 boolLike=0
- `SharedModules` `WamEventMobileConfigGeneralCases` — props=3 ivars=3 methods=0 boolLike=0
- `SharedModules` `WamEventMobileConfigInconsistentValue` — props=19 ivars=19 methods=0 boolLike=0
- `SharedModules` `WAMobileConfigSilentPushComparison` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `_TtC12WAFoundation20WAMobileConfigGating` — props=8 ivars=8 methods=17 boolLike=6
  - bool-like: `isTrueForKey:`, `isTrueForKey:default:`, `isFalseForKey:`, `isFalseForKey:default:`, `isEnabledForKey:default:`, `isExpensiveGatingEnabled`
- `SharedModules` `_TtC24WAMobileConfigNetworking21WAMobileConfigPlugin` — props=3 ivars=3 methods=0 boolLike=0
- `SharedModules` `_TtC24WAMobileConfigNetworking25WAMobileConfigPluginFetcher` — props=0 ivars=1 methods=0 boolLike=0
- `SharedModules` `_TtC24WAMobileConfigNetworking21WAMCResultMiddleware` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `_TtC24WAMobileConfigNetworking23WAMobileConfigTimestamp` — props=1 ivars=1 methods=7 boolLike=0

## WAAura

WA Plus/Aura is split: row/entrypoint in main app, benefit/subscription providers in WAAuraGating, themes/icons/foundation managers in WAAura/WAAuraFoundation.

Static classes matched: 28 · included in manifest: 28

- `SharedModules` `WAAuraGating` — props=23 ivars=7 methods=34 boolLike=25
  - bool-like: `isUserEligible`, `isAppThemesEnabled`, `isAppIconsEnabled`, `isRingtonesEnabled`, `isStickersEnabled`, `isEnhancedListsEnabled`, `isLoggingEnabled`, `isAppIconsBenefitActive`, `isAppThemesBenefitActive`, `isRingtonesBenefitActive`, `isEnhancedListsBenefitActive`, `isExtendedPinnedChatEnabled`
- `SharedModules` `_TtC12WAAuraGating28AuraBenefitReliabilityLogger` — props=0 ivars=5 methods=0 boolLike=0
- `SharedModules` `_TtC12WAAuraGating28SubscriptionUserActionLogger` — props=0 ivars=1 methods=0 boolLike=0
- `SharedModules` `_TtC12WAAuraGating20GatedBenefitProvider` — props=0 ivars=6 methods=1 boolLike=0
- `SharedModules` `_TtC12WAAuraGating25GatedSubscriptionProvider` — props=0 ivars=4 methods=1 boolLike=0
- `SharedModules` `_TtC12WAAuraGatingP33_0D07078F59E779AF4000BCB9D2AD4C5C24WhatsAppPlusSubscription` — props=0 ivars=4 methods=0 boolLike=0
- `SharedModules` `_TtC16WAAuraFoundation19ThemeColoringHelper` — props=0 ivars=2 methods=0 boolLike=0
- `WhatsApp` `_TtC6WAAura7AppIcon` — props=1 ivars=2 methods=4 boolLike=2
  - bool-like: `isEqual:`, `isEqualToAppIcon:`
- `WhatsApp` `WAAuraAppearanceSettingsString` — props=0 ivars=0 methods=0 boolLike=0
- `WhatsApp` `_TtC6WAAura25AppIconsScreenEventLogger` — props=0 ivars=0 methods=10 boolLike=0
- `WhatsApp` `_TtC6WAAura26AppThemesScreenEventLogger` — props=0 ivars=0 methods=10 boolLike=0
- `WhatsApp` `_TtC6WAAura25RingtoneScreenEventLogger` — props=0 ivars=0 methods=11 boolLike=0

## FOA_MetaAppUtilities

Family-of-apps / cross-app utilities. Includes app-installed booleans for Facebook/Instagram/Threads/MetaAI and routing utilities.

Static classes matched: 367 · included in manifest: 120

- `SharedModules` `_TtC19WACrossFamilyShared24FOAAppInstallationStatus` — props=3 ivars=3 methods=9 boolLike=3
  - bool-like: `isAppInstalled`, `isAppInstalledWithScheme:`, `canOpenURL:`
- `SharedModules` `WAFoaBridgesLogger` — props=0 ivars=1 methods=4 boolLike=0
- `SharedModules` `WAFoaType` — props=4 ivars=4 methods=12 boolLike=0
- `SharedModules` `WAFoaBridgesEventSource` — props=0 ivars=0 methods=25 boolLike=0
- `SharedModules` `WAFoaBridgesEventSurface` — props=0 ivars=0 methods=15 boolLike=0
- `SharedModules` `WAFoaBridgesDestination` — props=0 ivars=0 methods=6 boolLike=0
- `SharedModules` `WAFoaBridgesEventType` — props=0 ivars=0 methods=6 boolLike=0
- `SharedModules` `WAFoaBridgesUTMSource` — props=0 ivars=0 methods=3 boolLike=0
- `SharedModules` `WAFoaBridgesUTMCampaign` — props=0 ivars=0 methods=5 boolLike=0
- `SharedModules` `WAFoaBridgesLoggingEventParams` — props=0 ivars=8 methods=1 boolLike=0
- `SharedModules` `WAFoaBridgesURLParams` — props=0 ivars=2 methods=1 boolLike=0
- `SharedModules` `WAFoaRoutingContext` — props=0 ivars=5 methods=1 boolLike=0

## Contacts/About/OnlinePresence

About/Me-tab/contacts hub cluster. OnlinePresenceDotView is UI only; actual gate likely in WAAB/WAContext/WAContextMain services.

Static classes matched: 132 · included in manifest: 120

- `SharedModules` `WAUsername` — props=7 ivars=2 methods=17 boolLike=3
  - bool-like: `isEqualToWAUsername:`, `isEqual:`, `isValidIdentifier`
- `SharedModules` `WamEventAboutConsumption` — props=1 ivars=1 methods=0 boolLike=0
- `SharedModules` `WamEventAboutConsumptionDaily` — props=4 ivars=4 methods=0 boolLike=0
- `SharedModules` `WamEventAboutCreation` — props=10 ivars=9 methods=0 boolLike=0
- `SharedModules` `WamEventAboutCreationDaily` — props=6 ivars=6 methods=0 boolLike=0
- `SharedModules` `WamEventAboutInteraction` — props=2 ivars=2 methods=0 boolLike=0
- `SharedModules` `WamEventProfileAboutClick` — props=2 ivars=2 methods=0 boolLike=0
- `SharedModules` `WAContactTheme` — props=4 ivars=9 methods=0 boolLike=0
- `SharedModules` `_TtC14WAContactTheme22ThemeUpdateMessageData` — props=0 ivars=6 methods=0 boolLike=0
- `SharedModules` `_TtC14WAContactTheme21WAContactThemeManager` — props=0 ivars=4 methods=1 boolLike=0
- `SharedModules` `_TtC14WAContactTheme26ThemeClientPayloadBuilder` — props=0 ivars=1 methods=1 boolLike=0
- `SharedModules` `WAContactThemeV2` — props=7 ivars=9 methods=0 boolLike=0

## WABiz

Business feature surface; many classes carry abProperties ivars and should be grouped separately from generic Settings Rows.

Static classes matched: 235 · included in manifest: 120

- `SharedModules` `_TtC3JID19WABizAIHubConstants` — props=0 ivars=0 methods=8 boolLike=0
- `SharedModules` `WamEventBizProfileView` — props=14 ivars=14 methods=0 boolLike=0
- `SharedModules` `WamEventBizSearchConsumerEntrypointImpressions` — props=1 ivars=1 methods=0 boolLike=0
- `SharedModules` `WamEventBizSearchSmbEvents` — props=8 ivars=8 methods=0 boolLike=0
- `SharedModules` `WamEventCreateBizProfile` — props=9 ivars=9 methods=0 boolLike=0
- `SharedModules` `WamEventMaibaCoexBizProfileFetch` — props=2 ivars=2 methods=0 boolLike=0
- `SharedModules` `WABizBotHelper` — props=0 ivars=0 methods=7 boolLike=0
- `SharedModules` `_TtC5WABiz10BizManager` — props=0 ivars=7 methods=0 boolLike=0
- `SharedModules` `WABizManagerVerifiedNameDidUpdate` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WABizManagerProfileDidUpdate` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WABizProfileServerConfigsDidUpdate` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WABizPreferences` — props=0 ivars=0 methods=0 boolLike=0

## ModalNavigation

Modal/navigation infrastructure, probably not a feature-toggle group but needed for opening native surfaces safely.

Static classes matched: 6 · included in manifest: 6

- `SharedModules` `WAModalNavigationController` — props=0 ivars=0 methods=0 boolLike=0
- `SharedModules` `WAModalAppOverlay` — props=0 ivars=0 methods=10 boolLike=1
  - bool-like: `shouldAutorotate`
- `WhatsApp` `WAModalSplitViewGroupInfoViewController` — props=0 ivars=3 methods=5 boolLike=1
  - bool-like: `viewForHeaderInSection:shouldShowHeader:`
- `WhatsApp` `_TtC16WAModalSplitView24ModalSplitViewBottomView` — props=1 ivars=7 methods=7 boolLike=0
- `WhatsApp` `WAModalSplitViewController` — props=2 ivars=6 methods=10 boolLike=1
  - bool-like: `shouldPerformSegueWithIdentifier:sender:`
- `WhatsApp` `WAModalSplitViewPrimaryTableViewController` — props=0 ivars=2 methods=12 boolLike=0

## Relationships / patching implications

- `WAServerProperties.userContext` → `WAContext/WAContextMain` (high): WAServerProperties exposes class methods userContext/setUserContext/configureUserContext and class gates such as isInternalUser.
- `WAContext` → `WAContextMain` (high): SharedModules exposes WAContext as framework/container; main executable exposes WAContextMain with 91 properties / 80 ivars, matching concrete object graph.
- `WAABProperties` → `FOAWAABPropertiesImpl` (high): FOAWAABPropertiesImpl wraps abProperties and exposes boolForKey/stringForKey/integer/double accessors.
- `WAAuraGating.AuraGating` → `WAAura.AppThemesViewController/AppIconsViewController` (high): Gating Swift symbols expose isAppThemesEnabled/isAppIconsEnabled and main app exposes matching controllers.
- `WAAuraFoundation.AppThemeManager` → `WAAura.AppThemesViewController` (high): Foundation exposes activate/deactivate/appColorScheme while main controller owns app theme UI.
- `WAInfoTopHeaderView.OnlinePresenceDotView` → `Contacts/About/OnlinePresence` (medium): UI view only; actual gate likely in WAAB/WAContextMain contacts/MeTab services.
- `WAFoaAppUtilities` → `FOA_MetaAppUtilities` (high): Class properties expose installed-state booleans for Facebook, Instagram, Threads, MetaAI.
- `WABiz.BizManager` → `WABiz/WAABProperties` (high): Swift object has abProperties ivar and many business role/profile caches.

## Backup/import rule

The backup file must not be created as a random dump of live framework state. It should export only namespaced WATweaks preference/override keys, and import must remove any existing WATweaks key absent from the imported JSON. The inventory above is the mapping layer used to avoid orphan keys and duplicated feature groups.
