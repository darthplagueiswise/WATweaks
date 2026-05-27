// WAAuraHooks.xm — Aura / WA Plus gating helpers
// ─────────────────────────────────────────────────────────────────────────────
// This file owns only Aura WAAB/runtime gating hooks. Public navigation helpers
// and bulk activate/deactivate APIs are owned by WAGRAuraNavigationHooks.xm.
// Keeping one C-symbol owner avoids duplicate-symbol link failures.
// ─────────────────────────────────────────────────────────────────────────────

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

static NSArray<NSString *> *WAGRAuraPositiveFlags(void) {
    return @[
        @"aura_enabled",
        @"aura_settings_row_enabled",
        @"aura_subscription_simulation_enabled",
        @"aura_logging_enabled",
        @"aura_app_icon_enabled",
        @"aura_app_icon_benefit_active",
        @"aura_app_icon_multi_account_support",
        @"aura_app_themes_enabled",
        @"aura_app_themes_benefit_active",
        @"aura_app_themes_chat_checkmark_themed_enabled",
        @"aura_app_themes_new_selection_flow_enabled",
        @"aura_app_themes_share_extension_themed_enabled",
        @"aura_app_themes_status_ring_enabled",
        @"aura_app_themes_illustration_lottie_enabled",
        @"aura_apple_watch_app_theme_enabled",
        @"aura_apple_watch_app_themes_enabled",
        @"aura_pinned_chats_enabled",
        @"aura_pinned_chats_benefit_active",
        @"aura_pinned_chats_targeted_nux_force",
        @"aura_enhanced_lists_enabled",
        @"aura_enhanced_lists_benefit_active",
        @"aura_ringtones_enabled",
        @"aura_ringtones_benefit_active",
        @"aura_ringtones_per_chat_enabled",
        @"aura_stickers_enabled",
        @"aura_stickers_benefit_active",
        @"aura_stickers_overlay_animation_enabled",
        @"aura_painted_door_stickers_enabled",
        @"ai_subscription_enabled",
        @"ai_subscription_imagine_intent_enabled",
        @"isExpandedFormattingPlusEnabled",
        @"isEligibleForSubscriptions",
        @"isAppIconsBenefitActive",
        @"isAppThemesBenefitActive",
        @"isEnhancedListsBenefitActive",
        @"isExtendedPinnedChatBenefitActive",
        @"isRingtonesBenefitActive",
        @"isStickersBenefitActive",
        @"isSubscribedToAiBenefit",
        @"isAISubscriptionEnabled",
        @"wa_subscriptions_entry_point_settings_enabled",
        @"wa_subscriptions_settings_green_dot_enabled",
        @"premium_blue_enabled"
    ];
}

static NSArray<NSString *> *WAGRAuraNegativeFlags(void) {
    return @[
        @"aura_kill_switch",
        @"aura_premium_stickers_killswitch",
        @"aura_stickers_old_client_block_enabled"
    ];
}

static void WAGRSetWAABOverride(NSString *flag, NSString *value) {
    if (!flag.length) return;
    if (value.length) [[NSUserDefaults standardUserDefaults] setObject:value forKey:WAGRKey(flag)];
    else [[NSUserDefaults standardUserDefaults] removeObjectForKey:WAGRKey(flag)];
}

// ── WAAuraGating Swift/ObjC bridge hooks ─────────────────────────────────────
typedef BOOL (*WAGRAuraBoolIMP)(id, SEL);
static NSMutableDictionary<NSString *, NSValue *> *gAuraGatingOrig = nil;

static BOOL WAGRAuraSelectorIsNegative(NSString *sel) {
    NSString *lower = sel.lowercaseString ?: @"";
    if ([lower containsString:@"killswitch_disabled"] ||
        [lower containsString:@"kill_switch_disabled"]) {
        return NO;
    }

    return [lower containsString:@"killswitch"] ||
           [lower containsString:@"kill_switch"] ||
           [lower containsString:@"killswitchactive"] ||
           [lower containsString:@"kill"] ||
           [lower containsString:@"block"] ||
           [lower containsString:@"disabled"];
}

static BOOL hook_auraGatingBool(id self, SEL _cmd) {
    NSString *sel = NSStringFromSelector(_cmd);
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]), sel];

    WAGRAuraBoolIMP orig = NULL;
    NSValue *v = gAuraGatingOrig[key];
    if (v) orig = reinterpret_cast<WAGRAuraBoolIMP>([v pointerValue]);

    if (WAGRAuraSimulationEnabled() || WAGRIsOn(@"aura_enabled") || WAGRIsOn(@"aura_settings_row_enabled")) {
        return WAGRAuraSelectorIsNegative(sel) ? NO : YES;
    }
    return orig ? orig(self, _cmd) : NO;
}

static void WAGRHookAuraBoolSelectorOnClass(NSString *className, NSString *selectorName) {
    if (!className.length || !selectorName.length) return;
    Class cls = NSClassFromString(className);
    if (!cls) return;

    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (method_getNumberOfArguments(m) != 2) return;

    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
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
    return @[
        @"WAAuraGating",
        @"WAAuraGating.AuraGating",
        @"_TtC12WAAuraGating20GatedBenefitProvider",
        @"_TtC12WAAuraGating25GatedSubscriptionProvider"
    ];
}

static NSArray<NSString *> *WAGRAuraGatingSelectors(void) {
    return @[
        @"isEnabled",
        @"isUserEligible",
        @"isSettingsRowEnabled",
        @"isLoggingEnabled",
        @"isKillSwitchActive",
        @"isAppearanceSettingsEnabled",
        @"isAppIconsEnabled",
        @"isAppIconMultiAccountSupportEnabled",
        @"isAppIconsBenefitActive",
        @"isAppThemesEnabled",
        @"isAppThemesBenefitActive",
        @"isAppThemesChatCheckmarkThemedEnabled",
        @"isAppThemesStatusRingEnabled",
        @"isAppThemesLottieEnabled",
        @"isEnhancedListsEnabled",
        @"isEnhancedListsBenefitActive",
        @"isExtendedPinnedChatEnabled",
        @"isExtendedPinnedChatBenefitActive",
        @"isRingtonesEnabled",
        @"isRingtonesBenefitActive",
        @"isRingtonesPerChatEnabled",
        @"isStickersEnabled",
        @"isStickersBenefitActive",
        @"isSubscribedToAiBenefit",
        @"isAISubscriptionEnabled",
        @"isUserSubscribed"
    ];
}

extern "C" void WAGRAuraGatingSwiftHooksInstall(void) {
    for (NSString *cls in WAGRAuraGatingClassCandidates()) {
        for (NSString *sel in WAGRAuraGatingSelectors()) {
            WAGRHookAuraBoolSelectorOnClass(cls, sel);
        }
    }
}

extern "C" void WAGRAuraEnsureHooksInstalled(void) {
    if (!gAuraHooksInstalled) {
        gAuraHooksInstalled = YES;
        NSLog(@"[WATweaks][Aura] Aura fixed selector owner installed (navigation lives in WAGRAuraNavigationHooks)");
    }
    WAGRAuraGatingSwiftHooksInstall();
}

extern "C" NSString *WAGRAuraDiagnostic(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSUInteger positiveOn = 0;
    NSUInteger negativeOff = 0;
    for (NSString *flag in WAGRAuraPositiveFlags()) if ([[ud stringForKey:WAGRKey(flag)] isEqualToString:@"on"]) positiveOn++;
    for (NSString *flag in WAGRAuraNegativeFlags()) if ([[ud stringForKey:WAGRKey(flag)] isEqualToString:@"off"]) negativeOff++;
    NSMutableArray *loaded = [NSMutableArray array];
    for (NSString *cls in WAGRAuraGatingClassCandidates()) if (NSClassFromString(cls)) [loaded addObject:cls];
    return [NSString stringWithFormat:
            @"simulation=%@\npositive WAAB overrides=%lu/%lu\nnegative gates OFF=%lu/%lu\nsettings row owner=NativeSettingsRows\nrow-present policy=YES when forced\nSwift Aura classes loaded=%@\nSwift Aura bool hooks=%lu\nNative opener=%@\nOpen path: WhatsApp Settings > Subscriptions / WA Plus",
            WAGRAuraSimulationEnabled() ? @"ON" : @"OFF",
            (unsigned long)positiveOn, (unsigned long)WAGRAuraPositiveFlags().count,
            (unsigned long)negativeOff, (unsigned long)WAGRAuraNegativeFlags().count,
            loaded.count ? [loaded componentsJoinedByString:@", "] : @"none",
            (unsigned long)gAuraGatingOrig.count,
            WAGROpenSubscriptionsNative() ? @"found" : @"missing"];
}

// NOTE: WAGRAuraCtor was removed.
// WAAuraGating BOOL hooks are now installed via Logos %hook in
// WAGRGlobalGateStub.xm which runs at the correct time (after all ObjC
// images are initialized). The __attribute__((constructor)) path fired
// before SharedModules was mapped, so NSClassFromString always returned nil.
//
// WAGRAuraEnsureHooksInstalled() is still callable for the legacy
// MSHookMessageEx path (subclasses / GatedBenefitProvider ObjC surface).
