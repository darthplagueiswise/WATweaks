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
//   3. Settings rows are owned exclusively by WAGRSettingsRowsNativeHooks.xm.
//      This file must not hook WASettingsViewController. Keeping one owner
//      avoids chained trampolines and contradictory row-present answers.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

extern "C" void WAGRWAABEnsureHooksInstalled(void);
extern "C" void WAGRAuraEnsureHooksInstalled(void);

static NSString * const kWAGRAuraSimulationMaster = @"wagr_aura_simulation_enabled";
static BOOL gAuraHooksInstalled = NO;

static NSMutableDictionary<NSString *, NSValue *> *gAuraAppearanceOrig = nil;
static NSMutableSet<NSString *> *gAuraAppearanceHooked = nil;
static id gWAGRAuraLastUserContext = nil;
static NSUInteger gWAGRAuraAppearanceFactoryHookCount = 0;
static NSUInteger gWAGRAuraControllerContextFixCount = 0;

typedef id (*WAGRAuraIDCtxIMP)(id, SEL, id);
typedef void (*WAGRAuraVoidIMP)(id, SEL);

static NSString *WAGRAuraHookKey(NSString *className, NSString *selectorName, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@|%@|%@", className ?: @"", classMethod ? @"class" : @"inst", selectorName ?: @""];
}

static id WAGRAuraCurrentUserContext(void) {
    if (gWAGRAuraLastUserContext) return gWAGRAuraLastUserContext;

    NSArray<NSString *> *classNames = @[ @"WAServerProperties", @"WAContextMain", @"WAContext" ];
    NSArray<NSString *> *selectors = @[ @"userContext", @"sharedUserContext", @"currentUserContext", @"mainContext", @"sharedContext", @"defaultContext" ];

    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selectorName in selectors) {
            SEL sel = NSSelectorFromString(selectorName);
            if (![cls respondsToSelector:sel]) continue;
            id ctx = nil;
            @try { ctx = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel); }
            @catch (__unused NSException *ex) { ctx = nil; }
            if (ctx) {
                gWAGRAuraLastUserContext = ctx;
                return ctx;
            }
        }
    }
    return nil;
}

static id WAGRAuraContextFromController(id controller) {
    id cursor = controller;
    for (NSUInteger i = 0; cursor && i < 8; i++) {
        @try {
            id ctx = [cursor valueForKey:@"userContext"];
            if (ctx) {
                gWAGRAuraLastUserContext = ctx;
                return ctx;
            }
        } @catch (__unused NSException *ex) {}
        @try { cursor = [cursor valueForKey:@"parentViewController"]; }
        @catch (__unused NSException *ex) { cursor = nil; }
    }
    return WAGRAuraCurrentUserContext();
}

static void WAGRAuraInjectUserContextIntoController(id controller, id context) {
    if (!controller || !context) return;
    @try {
        id current = nil;
        @try { current = [controller valueForKey:@"userContext"]; } @catch (__unused NSException *ex) {}
        if (!current) {
            [controller setValue:context forKey:@"userContext"];
            gWAGRAuraControllerContextFixCount++;
            NSLog(@"[WATweaks][AuraVC] injected userContext into %@", NSStringFromClass([controller class]));
        }
    } @catch (__unused NSException *ex) {}
}

static id hook_WAGRAuraInitWithContext(id self, SEL _cmd, id context) {
    NSString *key = WAGRAuraHookKey(NSStringFromClass([self class]), NSStringFromSelector(_cmd), NO);
    WAGRAuraIDCtxIMP orig = NULL;
    NSValue *v = gAuraAppearanceOrig[key];
    if (v) orig = reinterpret_cast<WAGRAuraIDCtxIMP>([v pointerValue]);

    if (context) gWAGRAuraLastUserContext = context;
    id result = orig ? orig(self, _cmd, context) : self;
    if (context) WAGRAuraInjectUserContextIntoController(result, context);
    return result;
}

static id hook_WAGRAuraMakeControllerWithContext(id cls, SEL _cmd, id context) {
    NSString *key = WAGRAuraHookKey(NSStringFromClass((Class)cls), NSStringFromSelector(_cmd), YES);
    WAGRAuraIDCtxIMP orig = NULL;
    NSValue *v = gAuraAppearanceOrig[key];
    if (v) orig = reinterpret_cast<WAGRAuraIDCtxIMP>([v pointerValue]);

    id ctx = context ?: WAGRAuraCurrentUserContext();
    if (ctx) gWAGRAuraLastUserContext = ctx;

    id vc = orig ? orig(cls, _cmd, ctx ?: context) : nil;
    WAGRAuraInjectUserContextIntoController(vc, ctx);
    NSLog(@"[WATweaks][AuraVC] factory %@ returned %@ ctx=%@",
          NSStringFromSelector(_cmd), NSStringFromClass([vc class]), ctx ? @"YES" : @"NO");
    return vc;
}

static void hook_WAGRAuraControllerViewDidLoad(id self, SEL _cmd) {
    id ctx = WAGRAuraContextFromController(self);
    WAGRAuraInjectUserContextIntoController(self, ctx);

    NSString *key = WAGRAuraHookKey(NSStringFromClass([self class]), NSStringFromSelector(_cmd), NO);
    WAGRAuraVoidIMP orig = NULL;
    NSValue *v = gAuraAppearanceOrig[key];
    if (v) orig = reinterpret_cast<WAGRAuraVoidIMP>([v pointerValue]);
    if (orig) orig(self, _cmd);

    WAGRAuraInjectUserContextIntoController(self, ctx);
}

static BOOL WAGRAuraHookMessage(NSString *className, NSString *selectorName, BOOL classMethod, IMP replacement) {
    if (!className.length || !selectorName.length || !replacement) return NO;
    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    Class hookClass = classMethod ? object_getClass(cls) : cls;
    if (!hookClass) return NO;

    SEL sel = NSSelectorFromString(selectorName);
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    if (!gAuraAppearanceOrig) gAuraAppearanceOrig = [NSMutableDictionary dictionary];
    if (!gAuraAppearanceHooked) gAuraAppearanceHooked = [NSMutableSet set];

    NSString *key = WAGRAuraHookKey(className, selectorName, classMethod);
    if ([gAuraAppearanceHooked containsObject:key]) return YES;

    IMP orig = NULL;
    MSHookMessageEx(hookClass, sel, replacement, &orig);
    if (orig) {
        gAuraAppearanceOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
        [gAuraAppearanceHooked addObject:key];
        gWAGRAuraAppearanceFactoryHookCount++;
        NSLog(@"[WATweaks][AuraVC] hooked %@ %@%@", className, classMethod ? @"+" : @"-", selectorName);
        return YES;
    }
    return NO;
}

static void WAGRAuraAppearanceControllerHooksInstall(void) {
    WAGRAuraHookMessage(@"WAAppearanceSettingsViewController", @"initWithContext:", NO, (IMP)hook_WAGRAuraInitWithContext);
    WAGRAuraHookMessage(@"WAAppearanceSettingsViewController", @"makeAppIconViewControllerWithContext:", YES, (IMP)hook_WAGRAuraMakeControllerWithContext);
    WAGRAuraHookMessage(@"WAAppearanceSettingsViewController", @"makeAppThemeViewControllerWithContext:", YES, (IMP)hook_WAGRAuraMakeControllerWithContext);

    NSArray<NSString *> *controllers = @[
        @"WAAura.AppIconsViewController",
        @"WAAura.AppThemesViewController",
        @"WAAura.RingtonesViewController",
        @"WAAura.AppThemeViewController",
        @"WAAura.AppIconViewController"
    ];
    for (NSString *className in controllers) {
        WAGRAuraHookMessage(className, @"viewDidLoad", NO, (IMP)hook_WAGRAuraControllerViewDidLoad);
        WAGRAuraHookMessage(className, @"initWithContext:", NO, (IMP)hook_WAGRAuraInitWithContext);
    }
}

static UIViewController *WAGRAuraTopViewControllerFrom(UIViewController *from) {
    UIViewController *top = from;
    if (!top) {
        UIWindow *key = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        top = key.rootViewController;
    }
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) {
        top = ((UINavigationController *)top).topViewController;
    } else if ([top isKindOfClass:UITabBarController.class]) {
        top = ((UITabBarController *)top).selectedViewController;
        if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).topViewController;
    }
    return top;
}

static BOOL WAGRPushAuraFactoryController(UIViewController *from, NSString *factorySelector) {
    WAGRAuraEnsureHooksInstalled();

    Class settings = NSClassFromString(@"WAAppearanceSettingsViewController");
    SEL sel = NSSelectorFromString(factorySelector);
    if (!settings || ![settings respondsToSelector:sel]) {
        NSLog(@"[WATweaks][AuraVC] factory %@ missing on WAAppearanceSettingsViewController", factorySelector);
        return NO;
    }

    UIViewController *top = WAGRAuraTopViewControllerFrom(from);
    id ctx = WAGRAuraContextFromController(top);
    if (!ctx) ctx = WAGRAuraCurrentUserContext();

    id vc = ((id (*)(id, SEL, id))objc_msgSend)((id)settings, sel, ctx);
    if (![vc isKindOfClass:UIViewController.class]) {
        NSLog(@"[WATweaks][AuraVC] factory %@ did not return UIViewController", factorySelector);
        return NO;
    }

    WAGRAuraInjectUserContextIntoController(vc, ctx);

    UINavigationController *nav = top.navigationController;
    if (nav) {
        [nav pushViewController:(UIViewController *)vc animated:YES];
    } else {
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
        wrap.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:wrap animated:YES completion:nil];
    }
    return YES;
}


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

// Exposed as extern "C" so WAGRAccountEligibilityHooks.xm can read the
// same canonical Aura-simulation flag — keeping a single source of truth
// for "is Aura simulation on?" instead of duplicating the key lookup.
extern "C" BOOL WAGRAuraSimulationEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRAuraSimulationMaster];
}

static void WAGRSetWAABOverride(NSString *flag, NSString *value) {
    if (!flag.length) return;
    if (value.length) [[NSUserDefaults standardUserDefaults] setObject:value forKey:WAGRKey(flag)];
    else [[NSUserDefaults standardUserDefaults] removeObjectForKey:WAGRKey(flag)];
}

// ── Ownership note ───────────────────────────────────────────────────────────
// WASettingsViewController / Subscriptions row hooks live in
// WAGRSettingsRowsNativeHooks.xm. Aura only owns WAAB + WAAuraGating runtime
// gates. Do not re-add objc_copyClassList selector fishing here.

// ── WAAuraGating Swift/ObjC bridge hooks ─────────────────────────────────────
typedef BOOL (*WAGRAuraBoolIMP)(id, SEL);
static NSMutableDictionary<NSString *, NSValue *> *gAuraGatingOrig = nil;

static BOOL WAGRAuraSelectorIsNegative(NSString *sel) {
    NSString *lower = sel.lowercaseString ?: @"";

    // Explicit negative runtime getters. A switch ON in our UI should make
    // these return NO so the feature is unblocked.
    if ([lower containsString:@"killswitch_disabled"] ||
        [lower containsString:@"kill_switch_disabled"]) {
        return NO; // these are positive gates: TRUE means the kill switch is disabled
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
        NSLog(@"[WATweaks][Aura] Aura runtime owner installed (WASettingsViewController hooks are owned by WAGRSettingsRowsNativeHooks)");
    }
    WAGRAuraGatingSwiftHooksInstall();
    WAGRAuraAppearanceControllerHooksInstall();
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
    return WAGRPushAuraFactoryController(from, @"makeAppThemeViewControllerWithContext:");
}

extern "C" BOOL WAGRPushAuraIconsVC(UIViewController *from) {
    return WAGRPushAuraFactoryController(from, @"makeAppIconViewControllerWithContext:");
}

extern "C" BOOL WAGRPushAuraRingtonesVC(UIViewController *from) {
    (void)from;
    NSLog(@"[WATweaks][Aura] Ringtones VC direct init disabled; no native WAAppearanceSettings factory confirmed yet.");
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
            @"simulation=%@\npositive WAAB overrides=%lu/%lu\nnegative gates OFF=%lu/%lu\nsettings row owner=NativeSettingsRows\nrow-present policy=YES when forced\nSwift Aura classes loaded=%@\nSwift Aura bool hooks=%lu\nAura factory/context hooks=%lu\ncontroller context fixes=%lu\nlastUserContext=%@\nNative opener=%@\nOpen path: Settings > Appearance > App icons / App themes, or Settings > Subscriptions / WA Plus",
            WAGRAuraSimulationEnabled() ? @"ON" : @"OFF",
            (unsigned long)positiveOn, (unsigned long)WAGRAuraPositiveFlags().count,
            (unsigned long)negativeOff, (unsigned long)WAGRAuraNegativeFlags().count,
            loaded.count ? [loaded componentsJoinedByString:@", "] : @"none",
            (unsigned long)gAuraGatingOrig.count,
            (unsigned long)gWAGRAuraAppearanceFactoryHookCount,
            (unsigned long)gWAGRAuraControllerContextFixCount,
            gWAGRAuraLastUserContext ? NSStringFromClass([gWAGRAuraLastUserContext class]) : @"none",
            WAGROpenSubscriptionsNative() ? @"found" : @"missing"];
}

__attribute__((constructor))
static void WAGRAuraCtor(void) {
    @autoreleasepool {
        double delays[] = { 0.2, 0.8, 2.0 };
        for (int i = 0; i < (int)(sizeof(delays)/sizeof(delays[0])); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRAuraEnsureHooksInstalled(); });
        }
    }
}
