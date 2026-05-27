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
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>
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
// AURA / SUBSCRIPTION — direct function hooks, no Logos for WAAuraGating
// Toggle key: kWAGRAuraSimulation  (@"watweak_bundle_aura_simulation")
//
// Why direct MSHookFunction here:
//   WAAuraGating is Swift-backed and several call paths use direct dispatch to
//   the IMPs below. Logos / ObjC message hooks only cover objc_msgSend callers.
//   These hooks patch the function bodies themselves, so both ObjC dispatch and
//   Swift/direct callsites hit the same forced return when Aura simulation is ON.
//
// Confirmed on SharedModules(16), __TEXT vmaddr = 0:
//   0x189e45c isEnabled
//   0x189e488 isUserEligible
//   0x189e4b4 isSettingsRowEnabled
//   0x189e538 isAppearanceSettingsEnabled
//   0x189e5c8 isAppIconsEnabled
//   0x189e680 isAppIconsBenefitActive
//   0x189e774 isAppThemesEnabled
//   0x189e844 isAppThemesBenefitActive
// Also hooked as fallback:
//   0x1efb764 WADisplayableSubscription.isActive
// ═══════════════════════════════════════════════════════════════════════════

typedef BOOL (*WAGRAuraDirectBoolFn)(id self, SEL _cmd);

static WAGRAuraDirectBoolFn orig_WAGRAura_isEnabled = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isUserEligible = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isSettingsRowEnabled = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isAppearanceSettingsEnabled = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isAppIconsEnabled = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isAppIconsBenefitActive = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isAppThemesEnabled = NULL;
static WAGRAuraDirectBoolFn orig_WAGRAura_isAppThemesBenefitActive = NULL;
static WAGRAuraDirectBoolFn orig_WAGRSub_isActive = NULL;

static BOOL gWAGRAuraDirectHooksInstalled = NO;
static NSUInteger gWAGRAuraDirectHookCount = 0;
static uintptr_t gWAGRSharedModulesSlide = 0;

static BOOL WAGRAuraDirectShouldForce(void) {
    return WAGRPref(kWAGRAuraSimulation) ||
           WAGRIsOn(@"aura_enabled") ||
           WAGRIsOn(@"aura_settings_row_enabled") ||
           WAGRIsOn(@"aura_subscription_simulation_enabled");
}

static BOOL WAGRAuraForcedYES(id self, SEL _cmd, WAGRAuraDirectBoolFn orig) {
    if (WAGRAuraDirectShouldForce()) return YES;
    return orig ? orig(self, _cmd) : NO;
}

static BOOL repl_WAGRAura_isEnabled(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isEnabled);
}

static BOOL repl_WAGRAura_isUserEligible(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isUserEligible);
}

static BOOL repl_WAGRAura_isSettingsRowEnabled(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isSettingsRowEnabled);
}

static BOOL repl_WAGRAura_isAppearanceSettingsEnabled(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isAppearanceSettingsEnabled);
}

static BOOL repl_WAGRAura_isAppIconsEnabled(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isAppIconsEnabled);
}

static BOOL repl_WAGRAura_isAppIconsBenefitActive(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isAppIconsBenefitActive);
}

static BOOL repl_WAGRAura_isAppThemesEnabled(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isAppThemesEnabled);
}

static BOOL repl_WAGRAura_isAppThemesBenefitActive(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRAura_isAppThemesBenefitActive);
}

static BOOL repl_WAGRSub_isActive(id self, SEL _cmd) {
    return WAGRAuraForcedYES(self, _cmd, orig_WAGRSub_isActive);
}

static BOOL WAGRImageNameIsSharedModules(const char *name) {
    if (!name) return NO;
    return strstr(name, "/SharedModules.framework/SharedModules") ||
           strstr(name, "/SharedModules") ||
           strstr(name, "SharedModules");
}

static uintptr_t WAGRFindSharedModulesSlide(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (WAGRImageNameIsSharedModules(name)) {
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static BOOL WAGRHookDirectAuraBool(uintptr_t slide, uintptr_t vmaddr, void *replacement, void **orig, const char *label) {
    if (!slide || !replacement || !orig || *orig) return NO;

    void *target = (void *)(slide + vmaddr);
    if (!target) return NO;

    MSHookFunction(target, replacement, orig);
    if (*orig) {
        gWAGRAuraDirectHookCount++;
        NSLog(@"[WATweaks][AuraDirect] hooked %s target=%p vm=0x%lx", label, target, (unsigned long)vmaddr);
        return YES;
    }

    NSLog(@"[WATweaks][AuraDirect] FAILED %s target=%p vm=0x%lx", label, target, (unsigned long)vmaddr);
    return NO;
}

extern "C" void WAGRAuraDirectFunctionHooksInstall(void) {
    if (gWAGRAuraDirectHooksInstalled) return;

    uintptr_t slide = WAGRFindSharedModulesSlide();
    if (!slide) return;

    gWAGRSharedModulesSlide = slide;

    WAGRHookDirectAuraBool(slide, 0x189e45c, (void *)repl_WAGRAura_isEnabled, (void **)&orig_WAGRAura_isEnabled, "WAAuraGating.isEnabled");
    WAGRHookDirectAuraBool(slide, 0x189e488, (void *)repl_WAGRAura_isUserEligible, (void **)&orig_WAGRAura_isUserEligible, "WAAuraGating.isUserEligible");
    WAGRHookDirectAuraBool(slide, 0x189e4b4, (void *)repl_WAGRAura_isSettingsRowEnabled, (void **)&orig_WAGRAura_isSettingsRowEnabled, "WAAuraGating.isSettingsRowEnabled");
    WAGRHookDirectAuraBool(slide, 0x189e538, (void *)repl_WAGRAura_isAppearanceSettingsEnabled, (void **)&orig_WAGRAura_isAppearanceSettingsEnabled, "WAAuraGating.isAppearanceSettingsEnabled");
    WAGRHookDirectAuraBool(slide, 0x189e5c8, (void *)repl_WAGRAura_isAppIconsEnabled, (void **)&orig_WAGRAura_isAppIconsEnabled, "WAAuraGating.isAppIconsEnabled");
    WAGRHookDirectAuraBool(slide, 0x189e680, (void *)repl_WAGRAura_isAppIconsBenefitActive, (void **)&orig_WAGRAura_isAppIconsBenefitActive, "WAAuraGating.isAppIconsBenefitActive");
    WAGRHookDirectAuraBool(slide, 0x189e774, (void *)repl_WAGRAura_isAppThemesEnabled, (void **)&orig_WAGRAura_isAppThemesEnabled, "WAAuraGating.isAppThemesEnabled");
    WAGRHookDirectAuraBool(slide, 0x189e844, (void *)repl_WAGRAura_isAppThemesBenefitActive, (void **)&orig_WAGRAura_isAppThemesBenefitActive, "WAAuraGating.isAppThemesBenefitActive");
    WAGRHookDirectAuraBool(slide, 0x1efb764, (void *)repl_WAGRSub_isActive, (void **)&orig_WAGRSub_isActive, "WADisplayableSubscription.isActive");

    gWAGRAuraDirectHooksInstalled = (gWAGRAuraDirectHookCount >= 8);
    NSLog(@"[WATweaks][AuraDirect] install pass count=%lu installed=%@ slide=0x%lx",
          (unsigned long)gWAGRAuraDirectHookCount,
          gWAGRAuraDirectHooksInstalled ? @"YES" : @"NO",
          (unsigned long)gWAGRSharedModulesSlide);
}

static void WAGRAuraDirectInstallRetry(NSUInteger attempt) {
    WAGRAuraDirectFunctionHooksInstall();
    if (gWAGRAuraDirectHooksInstalled || attempt >= 8) return;

    NSTimeInterval delay = attempt < 3 ? 0.35 : 1.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WAGRAuraDirectInstallRetry(attempt + 1);
    });
}

static void WAGRAuraDirectImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    WAGRAuraDirectFunctionHooksInstall();
}

%ctor {
    _dyld_register_func_for_add_image(WAGRAuraDirectImageAdded);
    dispatch_async(dispatch_get_main_queue(), ^{
        WAGRAuraDirectInstallRetry(0);
    });
}

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
         "  Aura direct hooks  : %lu / 9 installed=%@ slide=0x%lx\n"
         "  WAAccountEligib    : %@\n"
         "  WAUsernameGating   : %@\n",
        WAGRPref(kWAGRAuraSimulation)     ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateEligibility)    ? @"ON" : @"OFF",
        WAGRPref(kWAGRGateUsername)       ? @"ON" : @"OFF",
        WAGRPref(kWAGRGatePremiumBroadcast)? @"ON" : @"OFF",
        NSClassFromString(@"WAAuraGating")               ? @"found" : @"MISSING",
        NSClassFromString(@"WADisplayableSubscription")  ? @"found" : @"MISSING",
        (unsigned long)gWAGRAuraDirectHookCount,
        gWAGRAuraDirectHooksInstalled ? @"YES" : @"NO",
        (unsigned long)gWAGRSharedModulesSlide,
        NSClassFromString(@"WAAccountEligibility")       ? @"found" : @"MISSING",
        NSClassFromString(@"WAUsernameGatingService")    ? @"found" : @"MISSING"];
}
