// WAGRAuraCompatExports.xm
// Single compatibility owner for Aura navigation/export symbols that older
// menus still call after WAGRAuraNavigationHooks.xm was removed as duplicate.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRAuraEnsureHooksInstalled(void);
extern "C" void WAGRAccountEligibilityEnsureHooksInstalled(void);
extern "C" NSString *WAGRAuraDiagnostic(void);
extern "C" NSString *WAGRAccountEligibilityDiagnostic(void);

static NSArray<NSString *> *WAGRAuraCompatPositiveKeys(void) {
    return @[
        kWAGRAuraSimulation,
        @"aura_enabled",
        @"aura_settings_row_enabled",
        @"aura_subscription_simulation_enabled",
        @"aura_logging_enabled",
        @"aura_app_icon_enabled",
        @"aura_app_icon_benefit_active",
        @"aura_app_themes_enabled",
        @"aura_app_themes_benefit_active",
        @"aura_enhanced_lists_enabled",
        @"aura_enhanced_lists_benefit_active",
        @"aura_ringtones_enabled",
        @"aura_ringtones_benefit_active",
        @"aura_stickers_enabled",
        @"aura_stickers_benefit_active",
        @"ai_subscription_enabled",
        @"isEligibleForSubscriptions",
        @"isAppIconsBenefitActive",
        @"isAppThemesBenefitActive",
        @"isEnhancedListsBenefitActive",
        @"isRingtonesBenefitActive",
        @"isStickersBenefitActive",
        @"isSubscribedToAiBenefit",
        @"isAISubscriptionEnabled",
        @"wa_subscriptions_entry_point_settings_enabled",
        @"wa_subscriptions_settings_green_dot_enabled",
        @"premium_blue_enabled"
    ];
}

static NSArray<NSString *> *WAGRAuraCompatNegativeKeys(void) {
    return @[ @"aura_kill_switch", @"aura_premium_stickers_killswitch", @"aura_stickers_old_client_block_enabled" ];
}

extern "C" BOOL WAGRAuraSimulationEnabled(void) {
    if (WAGRPref(kWAGRAuraSimulation)) return YES;
    if (WAGRGateIsSet(@"aura_subscription_simulation_enabled") && WAGRGateGet(@"aura_subscription_simulation_enabled")) return YES;
    if (WAGRGateIsSet(@"aura_enabled") && WAGRGateGet(@"aura_enabled")) return YES;
    return NO;
}

extern "C" void WAGRAuraActivateAllFlags(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setBool:YES forKey:kWAGRAuraSimulation];
    for (NSString *key in WAGRAuraCompatPositiveKeys()) WAGRGateSet(WAGRGateCanonicalKey(key), YES);
    for (NSString *key in WAGRAuraCompatNegativeKeys()) WAGRGateSet(WAGRGateCanonicalKey(key), NO);
    [ud synchronize];
    WAGRAuraEnsureHooksInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();
}

extern "C" void WAGRAuraDeactivateAllFlags(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud removeObjectForKey:kWAGRAuraSimulation];
    for (NSString *key in WAGRAuraCompatPositiveKeys()) WAGRGateClear(WAGRGateCanonicalKey(key));
    for (NSString *key in WAGRAuraCompatNegativeKeys()) WAGRGateClear(WAGRGateCanonicalKey(key));
    [ud synchronize];
}

extern "C" void WAGRAuraEnsureNavigationHooksInstalled(void) {
    WAGRAuraEnsureHooksInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();
}

extern "C" NSString *WAGRAuraNavigationDiagnostic(void) {
    NSString *aura = WAGRAuraDiagnostic();
    NSString *elig = WAGRAccountEligibilityDiagnostic();
    return [NSString stringWithFormat:@"Aura compat exports loaded\nsimulation=%@\n\n%@\n\n%@",
            WAGRAuraSimulationEnabled() ? @"ON" : @"OFF", aura ?: @"Aura: n/a", elig ?: @"Eligibility: n/a"];
}

extern "C" BOOL WAGROpenSubscriptionsNative(void) {
    // Kept as a safe capability probe for diagnostics. Opening native
    // subscription routes is intentionally left to WhatsApp's own settings flow.
    return NSClassFromString(@"WAAuraGating") || NSClassFromString(@"WAAccountEligibility");
}
