// WAGRGlobalGateStub.xm
// ─────────────────────────────────────────────────────────────────────────────
// Unified per-feature gating stubs using Logos %hook.
//
// WHY LOGOS INSTEAD OF MANUAL MSHookMessageEx:
//   The existing WAAuraHooks.xm installs hooks via __attribute__((constructor))
//   which fires before SharedModules.framework is mapped. NSClassFromString
//   returns nil at that point, so every hook silently fails to install.
//   Logos %hook + %ctor use the ObjC image callback mechanism — hooks are
//   applied after ALL images are initialized, guaranteeing the classes exist.
//
// ARCHITECTURE:
//   One master toggle per feature (WAGRPref → NSUserDefaults BOOL).
//   Each %hook covers the full method surface of its class so no method falls
//   through to the original "no" path when the toggle is on.
//
//   Negative selectors (killswitch, disabled, block) → return NO when toggled.
//   All others → return YES when toggled.
//
// CLASSES COVERED (confirmed via binary analysis on SharedModules + WhatsApp):
//   Aura/Subscription : WAAuraGating (SM, 23 BOOL), WADisplayableSubscription (SM)
//                       _TtC12WAAuraGating20GatedBenefitProvider (SM, via its ObjC surface)
//   Eligibility        : WAAccountEligibility (SM, 30 BOOL)
//   Username           : WAUsernameGatingService (WA, 9 BOOL)
//   PremiumBroadcast   : WAPremiumBroadcastGatingManager (WA, 26 BOOL)
//   LiquidGlass        : already owned by WAGRLiquidGlassHooks.xm — NOT duplicated here
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

// ── Helpers ───────────────────────────────────────────────────────────────────

// Returns YES if the selector name signals "this should be false" (kill-switch style).
static BOOL WAGRGateIsNegativeSel(SEL sel) {
    NSString *s = NSStringFromSelector(sel).lowercaseString;
    return [s containsString:@"killswitch"] ||
           [s containsString:@"kill_switch"] ||
           [s containsString:@"isblock"]    ||
           ([s containsString:@"disabled"] && ![s containsString:@"disable_if"]);
}

// Canonical bool value: YES for positive selectors, NO for kill-switch ones.
#define GATE_BOOL(key) \
    do { if (WAGRPref((key))) return WAGRGateIsNegativeSel(_cmd) ? NO : YES; } while(0)


// ═══════════════════════════════════════════════════════════════════════════
// AURA / SUBSCRIPTION
// Toggle key: kWAGRAuraSimulation  (@"watweak_bundle_aura_simulation")
// ═══════════════════════════════════════════════════════════════════════════

%hook WAAuraGating

// ── Core gates ────────────────────────────────────────────────────────────
- (BOOL)isEnabled                       { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isUserEligible                  { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isSettingsRowEnabled            { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isLoggingEnabled                { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isKillSwitchActive              { GATE_BOOL(kWAGRAuraSimulation); return %orig; } // → NO
- (BOOL)isAppearanceSettingsEnabled     { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

// ── App Icons ─────────────────────────────────────────────────────────────
- (BOOL)isAppIconsEnabled               { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isAppIconsBenefitActive         { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isAppIconMultiAccountSupportEnabled { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

// ── App Themes ────────────────────────────────────────────────────────────
- (BOOL)isAppThemesEnabled              { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isAppThemesBenefitActive        { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isAppThemesLottieEnabled        { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isAppThemeNewChatPreviewFlowEnabled { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

// ── Ringtones ─────────────────────────────────────────────────────────────
- (BOOL)isRingtonesEnabled              { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isRingtonesBenefitActive        { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isRingtonesPerChatEnabled       { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

// ── Extended Pinned Chats ─────────────────────────────────────────────────
- (BOOL)isExtendedPinnedChatEnabled     { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isExtendedPinnedChatBenefitActive { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

// ── Enhanced Lists ────────────────────────────────────────────────────────
- (BOOL)isEnhancedListsEnabled          { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isEnhancedListsBenefitActive    { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

// ── Stickers ──────────────────────────────────────────────────────────────
- (BOOL)isStickersEnabled               { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
- (BOOL)isStickersBenefitActive         { GATE_BOOL(kWAGRAuraSimulation); return %orig; }

%end


// WADisplayableSubscription — "is there an active subscription?"
// This is the class that the UI queries to decide whether to show premium
// content vs an upsell. Without this hook, all benefit-active checks return
// YES but the UI still shows "no subscription" because isActive = NO.
%hook WADisplayableSubscription
- (BOOL)isActive { GATE_BOOL(kWAGRAuraSimulation); return %orig; }
%end


// ═══════════════════════════════════════════════════════════════════════════
// ACCOUNT ELIGIBILITY
// Toggle key: kWAGRGateEligibility  (@"watweak_gate_eligibility_master")
// Covers broad eligibility gates: MetaAI, payments, channels, app-lock, etc.
// ═══════════════════════════════════════════════════════════════════════════

%hook WAAccountEligibility

- (BOOL)isLinkingModeOn                         { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForAppLock                    { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForChatLock                   { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForLocationSharing            { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForFOABookmarks               { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForCompanionSupport           { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isPAAEligibleForWaffle                  { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForMetaAI                     { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForDeepLinks                  { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForStatus                     { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForChannels                   { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForAvatarAutogen              { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForPayments                   { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleToJoinGroupsFromInvite        { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForWAMO                       { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForInterop                    { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForAllContentRatings          { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isAccountEligibleForCallLink            { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForSubscriptions              { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForLinks                      { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForSearchingNonContacts       { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isEligibleForContactManagement          { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isContactManagementEnabled              { GATE_BOOL(kWAGRGateEligibility); return %orig; }
- (BOOL)isAccountEligibleForGroupCreation       { GATE_BOOL(kWAGRGateEligibility); return %orig; }

%end


// ═══════════════════════════════════════════════════════════════════════════
// USERNAME
// Toggle key: kWAGRGateUsername  (@"watweak_gate_username_master")
// ═══════════════════════════════════════════════════════════════════════════

%hook WAUsernameGatingService

- (BOOL)isInReservationMode                    { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isInCreationMode                       { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isUsernameExperienceEnabled            { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isEligibleForActivation                { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isConsumerLinkingUpsellEnabled         { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isLinkedAccountDirectReservationEnabled { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isSMBLinkingEnabled                    { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)shouldShowReadOnlyBannerOnCompanion    { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)shouldShowUsernameRowOnCompanion       { GATE_BOOL(kWAGRGateUsername); return %orig; }

%end


// ═══════════════════════════════════════════════════════════════════════════
// PREMIUM BROADCAST (SMB Channels / Broadcast Lists)
// Toggle key: kWAGRGatePremiumBroadcast  (@"watweak_gate_premium_broadcast")
// ═══════════════════════════════════════════════════════════════════════════

%hook WAPremiumBroadcastGatingManager

- (BOOL)isPremiumBroadcastEnabled              { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isSystemMessagesEnabled                { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isNuxEnabled                           { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isCtaMessagesEnabledForChatSession:(id)s { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isThreadBannersEnabledForChatSession:(id)s { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isThreadsInChatHomeEnabled             { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isPremiumBroadcastEntryPointsEnabled   { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isIncreasedSendLimitEnabled            { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isIncreasedSendLimitPickerUIEnabled    { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isMessagePacksEnabled                  { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isMvBundlingEnabled                    { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isDocumentAttachmentEnabled            { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isCatalogAttachmentEnabled             { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isDuplicateBroadcastEnabled            { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isURLRestrictionEnabled                { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; } // → NO (restriction)
- (BOOL)isM2SuggestedAudienceEnabled           { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isConsumerBLCappingEnabled             { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isConsumerBLCappingNewBLHomeEnabled    { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isQPLLoggerEnabled                     { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isServerSendSuccessLoggingEnabled      { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isFreeMessageDeprecationEnabled        { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }

%end


// ═══════════════════════════════════════════════════════════════════════════
// DIAGNOSTICS
// ═══════════════════════════════════════════════════════════════════════════

extern "C" NSString *WAGRGlobalGateStubDiagnostic(void) {
    return [NSString stringWithFormat:
        @"GlobalGateStub loaded\n"
         "  Aura        : %@\n"
         "  Eligibility : %@\n"
         "  Username    : %@\n"
         "  PremiumBcast: %@\n"
         "  WAAuraGating class : %@\n"
         "  WADisplayableSub   : %@\n"
         "  WAAccountEligib    : %@\n"
         "  WAUsernameGating   : %@\n",
        WAGRPref(kWAGRAuraSimulation)     ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateEligibility)    ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateUsername)       ? @"ON" : @"OFF",
        WAGRPref(kWAGRGatePremiumBroadcast)? @"ON" : @"OFF",
        NSClassFromString(@"WAAuraGating")               ? @"found" : @"MISSING",
        NSClassFromString(@"WADisplayableSubscription")  ? @"found" : @"MISSING",
        NSClassFromString(@"WAAccountEligibility")       ? @"found" : @"MISSING",
        NSClassFromString(@"WAUsernameGatingService")    ? @"found" : @"MISSING"];
}
