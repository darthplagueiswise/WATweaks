// WAGRGlobalGateStub.xm
// ─────────────────────────────────────────────────────────────────────────────
// Unified per-feature gating stubs using Logos %hook.
//
// Crash note:
//   The previous alpha2 patch installed direct MSHookFunction hooks into
//   SharedModules text pages from a dyld image callback. On iOS 26.6 this
//   produced CODESIGNING / Invalid Page at WATweaks.dylib during startup.
//   Keep this file on ObjC/Logos-safe gates only; Aura fallback ObjC hooks live
//   in WAAuraHooks.xm.
//
// ARCHITECTURE:
//   One master toggle per feature (WAGRPref → NSUserDefaults BOOL).
//   Negative selectors (killswitch, disabled, block) → return NO when toggled.
//   All others → return YES when toggled.
//
// CLASSES COVERED (confirmed via binary analysis on SharedModules + WhatsApp):
//   Eligibility        : WAAccountEligibility (SM, 30 BOOL)
//   Username           : WAUsernameGatingService (WA, 9 BOOL)
//   PremiumBroadcast   : WAPremiumBroadcastGatingManager (WA, 26 BOOL)
//   LiquidGlass        : already owned by WAGRLiquidGlassHooks.xm — NOT duplicated here
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
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
         "  Aura direct hooks  : DISABLED (codesigning invalid-page guard)\n"
         "  Eligibility : %@\n"
         "  Username    : %@\n"
         "  PremiumBcast: %@\n"
         "  WAAccountEligib    : %@\n"
         "  WAUsernameGating   : %@\n",
        WAGRPref(kWAGRGateEligibility)    ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateUsername)       ? @"ON" : @"OFF",
        WAGRPref(kWAGRGatePremiumBroadcast)? @"ON" : @"OFF",
        NSClassFromString(@"WAAccountEligibility")       ? @"found" : @"MISSING",
        NSClassFromString(@"WAUsernameGatingService")    ? @"found" : @"MISSING"];
}
