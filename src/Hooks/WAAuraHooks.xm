// WAAuraHooks.xm — Aura / WA Plus settings-row helpers
// ─────────────────────────────────────────────────────────────────────────────
// Current architecture used here:
//   1. WAABProperties owns the AB flags that decide whether Aura / WA Plus UI
//      and Settings rows should be considered by the app.
//   2. SharedModules contains the Swift WAAuraGating module. Runtime/FLEX
//      confirms the important classes live there:
//        _TtC12WAAuraGating20GatedBenefitProvider
//        _TtC12WAAuraGating25GatedSubscriptionProvider
//        WAAuraGating / WAAuraGating.AuraGating bridged ObjC surfaces
//   3. Settings rows must be inserted through WhatsApp's own Settings flow.
//      We therefore hook the native “check/insert subscriptions row” path and
//      never instantiate Swift Aura view controllers with plain init().
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

extern "C" void WAGRWAABEnsureHooksInstalled(void);

static NSString * const kWAGRAuraSimulationMaster = @"wagr_aura_simulation_enabled";
static BOOL gAuraHooksInstalled = NO;

// ── WAAB flags that actually surface Aura / Settings rows ────────────────────
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

static BOOL WAGRAuraSimulationEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRAuraSimulationMaster];
}

static void WAGRSetWAABOverride(NSString *flag, NSString *value) {
    if (!flag.length) return;
    if (value.length) [[NSUserDefaults standardUserDefaults] setObject:value forKey:WAGRKey(flag)];
    else [[NSUserDefaults standardUserDefaults] removeObjectForKey:WAGRKey(flag)];
}

// ── Settings row insertion hooks ─────────────────────────────────────────────
static void (*orig_checkSubs)(id, SEL) = NULL;
static BOOL (*orig_isSubsRowPresent)(id, SEL) = NULL;

static void hook_checkSubs(id self, SEL _cmd) {
    if (orig_checkSubs) orig_checkSubs(self, _cmd);

    if (!WAGRIsOn(@"aura_settings_row_enabled")) return;

    SEL insertSel = NSSelectorFromString(@"insertSubscriptionsRow");
    if ([self respondsToSelector:insertSel]) {
        ((void (*)(id, SEL))objc_msgSend)(self, insertSel);
        NSLog(@"[WATweaks][Aura] direct insertSubscriptionsRow on %@", NSStringFromClass([self class]));
    }
}

static BOOL hook_isSubsRowPresent(id self, SEL _cmd) {
    if (!WAGRIsOn(@"aura_settings_row_enabled")) {
        return orig_isSubsRowPresent ? orig_isSubsRowPresent(self, _cmd) : NO;
    }
    // Force native code to believe it still needs to insert the row.
    return NO;
}

static void WAGRInstallOnFirstClass(const char *selName, IMP hook, IMP *orig) {
    if (!selName || !hook || !orig || *orig) return;
    SEL sel = sel_registerName(selName);
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    if (!all) return;
    for (unsigned int i = 0; i < n; i++) {
        Method m = class_getInstanceMethod(all[i], sel);
        if (!m) continue;
        MSHookMessageEx(all[i], sel, hook, orig);
        NSLog(@"[WATweaks][Aura] hooked -%s on %@", selName, NSStringFromClass(all[i]));
        break;
    }
    free(all);
}

// ── WAAuraGating Swift/ObjC bridge hooks ─────────────────────────────────────
typedef BOOL (*WAGRAuraBoolIMP)(id, SEL);
static NSMutableDictionary<NSString *, NSValue *> *gAuraGatingOrig = nil;

static BOOL WAGRAuraSelectorIsNegative(NSString *sel) {
    NSString *lower = sel.lowercaseString ?: @"";
    return [lower containsString:@"kill"] ||
           [lower containsString:@"block"] ||
           [lower containsString:@"disabled"] ||
           [lower containsString:@"hide"];
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

static BOOL WAGRAuraIsBoolNoArgMethod(Method m) {
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == 'B' || ret[0] == 'c';
}

static void WAGRHookAllAuraBoolMethodsOnClass(NSString *className) {
    if (!className.length) return;
    Class cls = NSClassFromString(className);
    if (!cls) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    if (!gAuraGatingOrig) gAuraGatingOrig = [NSMutableDictionary dictionary];
    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        if (!WAGRAuraIsBoolNoArgMethod(m)) continue;

        NSString *selectorName = NSStringFromSelector(method_getName(m));
        if (!selectorName.length) continue;

        // Keep this targeted to gate-like getters. FLEX shows WAAuraGating's
        // meaningful properties as isEnabled/isUserEligible/isSettingsRowEnabled
        // and benefit-style is*Active getters; the Swift provider subclasses may
        // expose fewer ObjC methods, so enumeration catches version drift.
        NSString *lower = selectorName.lowercaseString;
        BOOL looksLikeGate = [lower hasPrefix:@"is"] || [lower hasPrefix:@"has"] ||
                             [lower hasPrefix:@"should"] || [lower containsString:@"eligible"] ||
                             [lower containsString:@"enabled"] || [lower containsString:@"active"];
        if (!looksLikeGate) continue;

        NSString *origKey = [NSString stringWithFormat:@"%@|%@", className, selectorName];
        if (gAuraGatingOrig[origKey]) continue;

        IMP orig = NULL;
        MSHookMessageEx(cls, method_getName(m), (IMP)hook_auraGatingBool, &orig);
        if (orig) {
            gAuraGatingOrig[origKey] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
            NSLog(@"[WATweaks][AuraGating] auto-hooked %@ -%@", className, selectorName);
        }
    }
    free(methods);
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
        // First enumerate actual ObjC-visible BOOL properties/methods on the
        // loaded class. This matches what FLEX shows for WAAuraGating and avoids
        // depending only on hand-written selector guesses.
        WAGRHookAllAuraBoolMethodsOnClass(cls);

        // Then try known selector spellings for older/newer builds where a
        // method is present but not picked up by the initial property list.
        for (NSString *sel in WAGRAuraGatingSelectors()) {
            WAGRHookAuraBoolSelectorOnClass(cls, sel);
        }
    }
}

extern "C" void WAGRAuraEnsureHooksInstalled(void) {
    if (!gAuraHooksInstalled) {
        gAuraHooksInstalled = YES;
        WAGRInstallOnFirstClass("checkSubscriptionsEligibilityAndInsertRowIfNeeded",
                                (IMP)hook_checkSubs, (IMP *)&orig_checkSubs);
        WAGRInstallOnFirstClass("isSubscriptionsRowPresentInTable",
                                (IMP)hook_isSubsRowPresent, (IMP *)&orig_isSubsRowPresent);
    }
    WAGRAuraGatingSwiftHooksInstall();
    [[NSUserDefaults standardUserDefaults] synchronize];
}

extern "C" void WAGRAuraActivateAllFlags(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:kWAGRAuraSimulationMaster];
    for (NSString *flag in WAGRAuraPositiveFlags()) WAGRSetWAABOverride(flag, @"on");
    for (NSString *flag in WAGRAuraNegativeFlags()) WAGRSetWAABOverride(flag, @"off");
    [ud synchronize];
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
}

extern "C" void WAGRAuraDeactivateAllFlags(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:kWAGRAuraSimulationMaster];
    for (NSString *flag in WAGRAuraPositiveFlags()) WAGRSetWAABOverride(flag, nil);
    for (NSString *flag in WAGRAuraNegativeFlags()) WAGRSetWAABOverride(flag, nil);
    [ud synchronize];
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
}

// ── Safe navigation helpers ──────────────────────────────────────────────────
// Do not instantiate Swift Aura VCs with plain init(). Use native Settings rows.
extern "C" BOOL WAGROpenSubscriptionsNative(void) {
    SEL sel = NSSelectorFromString(@"openSettingsAndSubscriptionManagementWithUserInfo:");
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    if (!all) return NO;
    for (unsigned int i = 0; i < n; i++) {
        if (!class_getInstanceMethod(all[i], sel)) continue;
        NSLog(@"[WATweaks][Aura] native subscription opener exists on %@", NSStringFromClass(all[i]));
        free(all);
        return YES;
    }
    free(all);
    return NO;
}

extern "C" BOOL WAGRPushAuraThemesVC(UIViewController *from) {
    (void)from;
    NSLog(@"[WATweaks][Aura] Theme VC direct init disabled; open via Settings > Subscriptions / WA Plus.");
    return NO;
}

extern "C" BOOL WAGRPushAuraIconsVC(UIViewController *from) {
    (void)from;
    NSLog(@"[WATweaks][Aura] Icons VC direct init disabled; open via Settings > Subscriptions / WA Plus.");
    return NO;
}

extern "C" BOOL WAGRPushAuraRingtonesVC(UIViewController *from) {
    (void)from;
    NSLog(@"[WATweaks][Aura] Ringtones VC direct init disabled; open via Settings > Subscriptions / WA Plus.");
    return NO;
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
            @"simulation=%@\npositive WAAB overrides=%lu/%lu\nnegative gates OFF=%lu/%lu\nsettings row hook=%@\nrow-present hook=%@\nSwift Aura classes loaded=%@\nSwift Aura bool hooks=%lu\nNative opener=%@\nOpen path: WhatsApp Settings > Subscriptions / WA Plus",
            WAGRAuraSimulationEnabled() ? @"ON" : @"OFF",
            (unsigned long)positiveOn, (unsigned long)WAGRAuraPositiveFlags().count,
            (unsigned long)negativeOff, (unsigned long)WAGRAuraNegativeFlags().count,
            orig_checkSubs ? @"YES" : @"NO",
            orig_isSubsRowPresent ? @"YES" : @"NO",
            loaded.count ? [loaded componentsJoinedByString:@", "] : @"none",
            (unsigned long)gAuraGatingOrig.count,
            WAGROpenSubscriptionsNative() ? @"found" : @"missing"];
}

__attribute__((constructor))
static void WAGRAuraCtor(void) {
    @autoreleasepool {
        double delays[] = { 0.8, 2.0, 4.0, 7.0 };
        for (int i = 0; i < (int)(sizeof(delays)/sizeof(delays[0])); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRAuraEnsureHooksInstalled(); });
        }
    }
}
