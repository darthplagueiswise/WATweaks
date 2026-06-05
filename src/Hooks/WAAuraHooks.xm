// WAAuraHooks.xm — Aura / WA Plus gating helpers
// SDK 26.2 refresh: WAAuraGating is a real ObjC-visible class in SharedModules.
// This uses Aura's own simulation flag family (aura_subscription_simulation_enabled), not a credential/subscription bypass.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

extern "C" void WAGRWAABEnsureHooksInstalled(void);
extern "C" BOOL WAGRAuraSimulationEnabled(void);
extern "C" BOOL WAGROpenSubscriptionsNative(void);

static BOOL gAuraHooksInstalled = NO;
static NSMutableDictionary<NSString *, NSValue *> *gAuraGatingOrig = nil;

typedef BOOL (*WAGRAuraBoolIMP)(id, SEL);

static NSArray<NSString *> *WAGRAuraPositiveFlags(void) {
    return @[
        @"aura_enabled", @"aura_settings_row_enabled", @"aura_subscription_simulation_enabled", @"aura_logging_enabled",
        @"aura_app_icon_enabled", @"aura_app_icon_benefit_active", @"aura_app_icon_multi_account_support",
        @"aura_app_themes_enabled", @"aura_app_themes_benefit_active", @"aura_app_themes_chat_checkmark_themed_enabled",
        @"aura_app_themes_new_selection_flow_enabled", @"aura_app_themes_share_extension_themed_enabled",
        @"aura_app_themes_status_ring_enabled", @"aura_app_themes_illustration_lottie_enabled",
        @"aura_apple_watch_app_theme_enabled", @"aura_apple_watch_app_themes_enabled",
        @"aura_pinned_chats_enabled", @"aura_pinned_chats_benefit_active", @"aura_pinned_chats_targeted_nux_force",
        @"aura_enhanced_lists_enabled", @"aura_enhanced_lists_benefit_active",
        @"aura_ringtones_enabled", @"aura_ringtones_benefit_active", @"aura_ringtones_per_chat_enabled",
        @"aura_stickers_enabled", @"aura_stickers_benefit_active", @"aura_stickers_overlay_animation_enabled",
        @"aura_painted_door_stickers_enabled", @"aura_vault_backups_enabled", @"aura_vault_backups_benefit_active",
        @"ai_subscription_enabled", @"ai_subscription_imagine_intent_enabled", @"ai_subscription_metering_enabled",
        @"isExpandedFormattingPlusEnabled", @"isEligibleForSubscriptions",
        @"isAppIconsBenefitActive", @"isAppThemesBenefitActive", @"isEnhancedListsBenefitActive",
        @"isExtendedPinnedChatBenefitActive", @"isRingtonesBenefitActive", @"isStickersBenefitActive",
        @"isSubscribedToAiBenefit", @"isAISubscriptionEnabled",
        @"wa_subscriptions_entry_point_settings_enabled", @"wa_subscriptions_settings_green_dot_enabled", @"premium_blue_enabled"
    ];
}

static NSArray<NSString *> *WAGRAuraNegativeFlags(void) {
    return @[ @"aura_kill_switch", @"aura_premium_stickers_killswitch", @"aura_stickers_old_client_block_enabled" ];
}

static BOOL WAGRAuraSelectorIsNegative(NSString *sel) {
    NSString *lower = sel.lowercaseString ?: @"";
    if ([lower containsString:@"killswitch_disabled"] || [lower containsString:@"kill_switch_disabled"]) return NO;
    return [lower containsString:@"killswitch"] || [lower containsString:@"kill_switch"] || [lower containsString:@"killswitchactive"] || [lower containsString:@"kill"] || [lower containsString:@"block"] || [lower containsString:@"disabled"];
}

static BOOL hook_auraGatingBool(id self, SEL _cmd) {
    NSString *sel = NSStringFromSelector(_cmd);
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]), sel];
    WAGRAuraBoolIMP orig = NULL;
    NSValue *v = gAuraGatingOrig[key];
    if (v) orig = reinterpret_cast<WAGRAuraBoolIMP>([v pointerValue]);
    BOOL original = orig ? orig(self, _cmd) : NO;
    if (WAGRAuraSimulationEnabled() || WAGRIsOn(@"aura_enabled") || WAGRIsOn(@"aura_settings_row_enabled") || WAGRIsOn(@"aura_subscription_simulation_enabled")) {
        return WAGRAuraSelectorIsNegative(sel) ? NO : YES;
    }
    return original;
}

static void WAGRHookAuraBoolSelectorOnClass(NSString *className, NSString *selectorName) {
    if (!className.length || !selectorName.length) return;
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    if (!cls) return;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return;
    char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'B' && ret[0] != 'c') return;
    if (!gAuraGatingOrig) gAuraGatingOrig = [NSMutableDictionary dictionary];
    NSString *origKey = [NSString stringWithFormat:@"%@|%@", className, selectorName];
    if (gAuraGatingOrig[origKey]) return;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)hook_auraGatingBool, &orig);
    if (orig) {
        gAuraGatingOrig[origKey] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
        NSLog(@"[WATweaks][AuraGating] hooked %@ -%@", className, selectorName);
    }
}

static NSArray<NSString *> *WAGRAuraGatingClassCandidates(void) {
    return @[ @"WAAuraGating", @"WAAuraGating.AuraGating", @"_TtC12WAAuraGating20GatedBenefitProvider", @"_TtC12WAAuraGating25GatedSubscriptionProvider" ];
}

static NSArray<NSString *> *WAGRAuraGatingSelectors(void) {
    return @[
        @"isEnabled", @"isUserEligible", @"isSettingsRowEnabled", @"isLoggingEnabled", @"isKillSwitchActive",
        @"isAppearanceSettingsEnabled", @"isAppIconsEnabled", @"isAppIconMultiAccountSupportEnabled", @"isAppIconsBenefitActive",
        @"isAppThemesEnabled", @"isAppThemesBenefitActive", @"isAppThemesChatCheckmarkThemedEnabled",
        @"isAppThemesStatusRingEnabled", @"isAppThemesLottieEnabled", @"isAppThemeNewChatPreviewFlowEnabled",
        @"isEnhancedListsEnabled", @"isEnhancedListsBenefitActive", @"isExtendedPinnedChatEnabled", @"isExtendedPinnedChatBenefitActive",
        @"isRingtonesEnabled", @"isRingtonesBenefitActive", @"isRingtonesPerChatEnabled",
        @"isStickersEnabled", @"isStickersBenefitActive", @"isSubscribedToAiBenefit", @"isAISubscriptionEnabled", @"isUserSubscribed"
    ];
}

extern "C" void WAGRAuraGatingSwiftHooksInstall(void) {
    for (NSString *cls in WAGRAuraGatingClassCandidates()) {
        for (NSString *sel in WAGRAuraGatingSelectors()) WAGRHookAuraBoolSelectorOnClass(cls, sel);
    }
}

extern "C" void WAGRAuraEnsureHooksInstalled(void) {
    if (!gAuraHooksInstalled) {
        gAuraHooksInstalled = YES;
        NSLog(@"[WATweaks][Aura] Aura simulation selector owner installed (navigation lives in WAGRAuraNavigationHooks)");
    }
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraGatingSwiftHooksInstall();
}

extern "C" NSString *WAGRAuraDiagnostic(void) {
    NSUInteger positiveOn = 0, negativeOff = 0;
    for (NSString *flag in WAGRAuraPositiveFlags()) if (WAGRGateIsSet(flag) && WAGRGateGet(flag)) positiveOn++;
    for (NSString *flag in WAGRAuraNegativeFlags()) if (WAGRGateIsSet(flag) && !WAGRGateGet(flag)) negativeOff++;
    NSMutableArray *loaded = [NSMutableArray array];
    for (NSString *cls in WAGRAuraGatingClassCandidates()) if (NSClassFromString(cls) || objc_getClass(cls.UTF8String)) [loaded addObject:cls];
    return [NSString stringWithFormat:
            @"simulation=%@\naura_subscription_simulation=%@\npositive WAAB overrides=%lu/%lu\nnegative gates OFF=%lu/%lu\nSwift/ObjC Aura classes loaded=%@\nAura ObjC hooks=%lu\nNative opener=%@\nOpen path: WhatsApp Settings > Subscriptions / WA Plus",
            WAGRAuraSimulationEnabled() ? @"ON" : @"OFF",
            (WAGRGateIsSet(@"aura_subscription_simulation_enabled") && WAGRGateGet(@"aura_subscription_simulation_enabled")) ? @"ON" : @"OFF",
            (unsigned long)positiveOn, (unsigned long)WAGRAuraPositiveFlags().count,
            (unsigned long)negativeOff, (unsigned long)WAGRAuraNegativeFlags().count,
            loaded.count ? [loaded componentsJoinedByString:@", "] : @"none",
            (unsigned long)gAuraGatingOrig.count,
            WAGROpenSubscriptionsNative() ? @"found" : @"missing"];
}

__attribute__((constructor))
static void WAGRAuraCtor(void) {
    @autoreleasepool {
        WAGRAuraEnsureHooksInstalled();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRAuraEnsureHooksInstalled(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRAuraEnsureHooksInstalled(); });
    }
}
