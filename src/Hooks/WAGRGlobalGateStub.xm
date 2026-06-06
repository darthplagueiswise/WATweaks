// WAGRGlobalGateStub.xm
// ─────────────────────────────────────────────────────────────────────────────
// Unified per-feature gating stubs using Logos %hook.
// ObjC/Logos-safe only; no direct text-page rebinding here.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "../WAGramPrefix.h"

// These constants are also declared in WAGramPrefix.h. Keep local fallbacks so
// this hook file never breaks when the shared prefix is refactored.
#ifndef kWAGRGateEligibility
#define kWAGRGateEligibility @"watweak_gate_eligibility_master"
#endif
#ifndef kWAGRGateUsername
#define kWAGRGateUsername @"watweak_gate_username_master"
#endif
#ifndef kWAGRGatePremiumBroadcast
#define kWAGRGatePremiumBroadcast @"watweak_gate_premium_broadcast"
#endif

static BOOL WAGRGateIsNegativeSel(SEL sel) {
    NSString *s = NSStringFromSelector(sel).lowercaseString;
    return [s containsString:@"killswitch"] ||
           [s containsString:@"kill_switch"] ||
           [s containsString:@"isblock"] ||
           ([s containsString:@"disabled"] && ![s containsString:@"disable_if"]);
}

#define GATE_BOOL(key) \
    do { if (WAGRPref((key))) return WAGRGateIsNegativeSel(_cmd) ? NO : YES; } while(0)

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

%hook WAUsernameGatingService
- (BOOL)isInReservationMode                     { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isInCreationMode                        { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isUsernameExperienceEnabled             { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isEligibleForActivation                 { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isConsumerLinkingUpsellEnabled          { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isLinkedAccountDirectReservationEnabled { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)isSMBLinkingEnabled                     { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)shouldShowReadOnlyBannerOnCompanion     { GATE_BOOL(kWAGRGateUsername); return %orig; }
- (BOOL)shouldShowUsernameRowOnCompanion        { GATE_BOOL(kWAGRGateUsername); return %orig; }
%end

%hook WAPremiumBroadcastGatingManager
- (BOOL)isPremiumBroadcastEnabled               { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isSystemMessagesEnabled                 { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isNuxEnabled                            { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isCtaMessagesEnabledForChatSession:(id)s { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isThreadBannersEnabledForChatSession:(id)s { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isThreadsInChatHomeEnabled              { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isPremiumBroadcastEntryPointsEnabled    { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isIncreasedSendLimitEnabled             { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isIncreasedSendLimitPickerUIEnabled     { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isMessagePacksEnabled                   { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isMvBundlingEnabled                     { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isDocumentAttachmentEnabled             { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isCatalogAttachmentEnabled              { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isDuplicateBroadcastEnabled             { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isURLRestrictionEnabled                 { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isM2SuggestedAudienceEnabled            { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isConsumerBLCappingEnabled              { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isConsumerBLCappingNewBLHomeEnabled     { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isQPLLoggerEnabled                      { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isServerSendSuccessLoggingEnabled       { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
- (BOOL)isFreeMessageDeprecationEnabled         { GATE_BOOL(kWAGRGatePremiumBroadcast); return %orig; }
%end

extern "C" NSString *WAGRGlobalGateStubDiagnostic(void) {
    return [NSString stringWithFormat:
        @"GlobalGateStub loaded\n  Eligibility : %@\n  Username    : %@\n  PremiumBcast: %@\n  WAAccountEligib : %@\n  WAUsernameGating: %@",
        WAGRPref(kWAGRGateEligibility) ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateUsername) ? @"ON" : @"OFF",
        WAGRPref(kWAGRGatePremiumBroadcast) ? @"ON" : @"OFF",
        NSClassFromString(@"WAAccountEligibility") ? @"found" : @"MISSING",
        NSClassFromString(@"WAUsernameGatingService") ? @"found" : @"MISSING"];
}
