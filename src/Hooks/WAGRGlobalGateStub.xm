// WAGRGlobalGateStub.xm
// ─────────────────────────────────────────────────────────────────────────────
// Unified per-feature gating stubs using Logos %hook.
//
// Crash note:
//   Direct MSHookFunction hooks into SharedModules text pages caused
//   CODESIGNING / Invalid Page during startup. Keep this file restricted to
//   Objective-C methods installed through Logos.
//
// Logos note:
//   Do not compress these hooks into one-line method definitions containing a
//   macro with return statements. Logos can generate unterminated C++ function
//   bodies from that form. Keep every method body explicit and multiline.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "../WAGramPrefix.h"

static BOOL WAGRGateIsNegativeSelector(SEL selector) {
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    return [name containsString:@"killswitch"] ||
           [name containsString:@"kill_switch"] ||
           [name containsString:@"isblock"] ||
           ([name containsString:@"disabled"] &&
            ![name containsString:@"disable_if"]);
}

static BOOL WAGRResolveGateOverride(NSString *key,
                                    SEL selector,
                                    BOOL *value) {
    if (!WAGRPref(key)) return NO;
    if (value) {
        *value = WAGRGateIsNegativeSelector(selector) ? NO : YES;
    }
    return YES;
}

// ── Account eligibility ──────────────────────────────────────────────────────

%hook WAAccountEligibility

- (BOOL)isLinkingModeOn {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForAppLock {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForChatLock {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForLocationSharing {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForFOABookmarks {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForCompanionSupport {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isPAAEligibleForWaffle {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForMetaAI {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForDeepLinks {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForStatus {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForChannels {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForAvatarAutogen {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForPayments {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleToJoinGroupsFromInvite {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForWAMO {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForInterop {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForAllContentRatings {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isAccountEligibleForCallLink {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForSubscriptions {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForLinks {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForSearchingNonContacts {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForContactManagement {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isContactManagementEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isAccountEligibleForGroupCreation {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateEligibility, _cmd, &value)) return value;
    return %orig;
}

%end

// ── Username ─────────────────────────────────────────────────────────────────

%hook WAUsernameGatingService

- (BOOL)isInReservationMode {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isInCreationMode {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isUsernameExperienceEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isEligibleForActivation {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isConsumerLinkingUpsellEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isLinkedAccountDirectReservationEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isSMBLinkingEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)shouldShowReadOnlyBannerOnCompanion {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)shouldShowUsernameRowOnCompanion {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGateUsername, _cmd, &value)) return value;
    return %orig;
}

%end

// ── Premium broadcast ────────────────────────────────────────────────────────

%hook WAPremiumBroadcastGatingManager

- (BOOL)isPremiumBroadcastEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isSystemMessagesEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isNuxEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isCtaMessagesEnabledForChatSession:(id)session {
    (void)session;
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isThreadBannersEnabledForChatSession:(id)session {
    (void)session;
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isThreadsInChatHomeEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isPremiumBroadcastEntryPointsEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isIncreasedSendLimitEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isIncreasedSendLimitPickerUIEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isMessagePacksEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isMvBundlingEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isDocumentAttachmentEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isCatalogAttachmentEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isDuplicateBroadcastEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isURLRestrictionEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isM2SuggestedAudienceEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isConsumerBLCappingEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isConsumerBLCappingNewBLHomeEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isQPLLoggerEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isServerSendSuccessLoggingEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

- (BOOL)isFreeMessageDeprecationEnabled {
    BOOL value = NO;
    if (WAGRResolveGateOverride(kWAGRGatePremiumBroadcast, _cmd, &value)) return value;
    return %orig;
}

%end

extern "C" NSString *WAGRGlobalGateStubDiagnostic(void) {
    return [NSString stringWithFormat:
        @"GlobalGateStub loaded\n"
         "  Aura direct hooks  : DISABLED (codesigning invalid-page guard)\n"
         "  Eligibility : %@\n"
         "  Username    : %@\n"
         "  PremiumBcast: %@\n"
         "  WAAccountEligib    : %@\n"
         "  WAUsernameGating   : %@\n",
        WAGRPref(kWAGRGateEligibility) ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateUsername) ? @"ON" : @"OFF",
        WAGRPref(kWAGRGatePremiumBroadcast) ? @"ON" : @"OFF",
        NSClassFromString(@"WAAccountEligibility") ? @"found" : @"MISSING",
        NSClassFromString(@"WAUsernameGatingService") ? @"found" : @"MISSING"];
}
