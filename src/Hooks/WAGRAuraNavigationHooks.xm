// WAGRAuraNavigationHooks.xm — Aura navigation and bulk-flag helpers.
// ─────────────────────────────────────────────────────────────────────────────
// Purpose
// ───────
// This file owns the Aura *navigation* surface — the factory hooks that
// inject userContext into WAAppearanceSettingsViewController-spawned VCs,
// the push helpers for opening App Themes / App Icons screens directly,
// and the bulk activate/deactivate of the Aura flag set.
//
// What this file does NOT own (any longer)
// ────────────────────────────────────────
// Per-selector BOOL gating hooks for the Aura classes. Those are installed
// by WAGRGateHooks.xm via the schema-v2 store (key = selector name). The
// split keeps the "navigation safety net" — which has to keep working even
// if no gate is overridden — separate from the "gate override engine".
//
// Public API (extern "C")
// ───────────────────────
//   WAGRAuraEnsureNavigationHooksInstalled() — install factory/init hooks
//   WAGRAuraSimulationEnabled()              — read kWAGRAuraSimulation
//   WAGRAuraActivateAllFlags()               — bulk write Aura overrides
//   WAGRAuraDeactivateAllFlags()             — bulk clear Aura overrides
//   WAGRPushAuraThemesVC(from)               — push App Themes VC
//   WAGRPushAuraIconsVC(from)                — push App Icons VC
//   WAGRPushAuraRingtonesVC(from)            — placeholder, returns NO
//   WAGROpenSubscriptionsNative()            — probe for native opener
//   WAGRAuraNavigationDiagnostic()           — short status string
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRGateHooksEnsureInstalled(void);

// ── Static state ─────────────────────────────────────────────────────────────
static NSMutableDictionary<NSString *, NSValue *> *gNavOrig = nil;
static NSMutableSet<NSString *> *gNavHooked = nil;
static id gNavLastUserContext = nil;
static NSUInteger gNavFactoryCount = 0;
static NSUInteger gNavContextFixCount = 0;
static BOOL gNavInstalled = NO;

typedef id   (*WAGRNavIDCtxIMP)(id, SEL, id);
typedef void (*WAGRNavVoidIMP)(id, SEL);

static NSString *WAGRNavHookKey(NSString *className, NSString *selectorName, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            className ?: @"", classMethod ? @"class" : @"inst", selectorName ?: @""];
}

// ── userContext discovery ────────────────────────────────────────────────────
static id WAGRNavCurrentUserContext(void) {
    if (gNavLastUserContext) return gNavLastUserContext;

    NSArray<NSString *> *classNames = @[ @"WAServerProperties", @"WAContextMain", @"WAContext" ];
    NSArray<NSString *> *selectors = @[
        @"userContext", @"sharedUserContext", @"currentUserContext",
        @"mainContext", @"sharedContext", @"defaultContext"
    ];

    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selectorName in selectors) {
            SEL sel = NSSelectorFromString(selectorName);
            if (![cls respondsToSelector:sel]) continue;
            id ctx = nil;
            @try { ctx = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel); }
            @catch (__unused NSException *ex) { ctx = nil; }
            if (ctx) { gNavLastUserContext = ctx; return ctx; }
        }
    }
    return nil;
}

static id WAGRNavContextFromController(id controller) {
    id cursor = controller;
    for (NSUInteger i = 0; cursor && i < 8; i++) {
        @try {
            id ctx = [cursor valueForKey:@"userContext"];
            if (ctx) { gNavLastUserContext = ctx; return ctx; }
        } @catch (__unused NSException *ex) {}
        @try { cursor = [cursor valueForKey:@"parentViewController"]; }
        @catch (__unused NSException *ex) { cursor = nil; }
    }
    return WAGRNavCurrentUserContext();
}

static void WAGRNavInjectUserContextIntoController(id controller, id context) {
    if (!controller || !context) return;
    @try {
        id current = nil;
        @try { current = [controller valueForKey:@"userContext"]; } @catch (__unused NSException *ex) {}
        if (!current) {
            [controller setValue:context forKey:@"userContext"];
            gNavContextFixCount++;
            NSLog(@"[WATweaks][AuraNav] injected userContext into %@", NSStringFromClass([controller class]));
        }
    } @catch (__unused NSException *ex) {}
}

// ── Factory / init trampolines ───────────────────────────────────────────────
static id hook_navInitWithContext(id self, SEL _cmd, id context) {
    NSString *key = WAGRNavHookKey(NSStringFromClass([self class]), NSStringFromSelector(_cmd), NO);
    WAGRNavIDCtxIMP orig = NULL;
    NSValue *v = gNavOrig[key];
    if (v) orig = (WAGRNavIDCtxIMP)[v pointerValue];

    if (context) gNavLastUserContext = context;
    id result = orig ? orig(self, _cmd, context) : self;
    if (context) WAGRNavInjectUserContextIntoController(result, context);
    return result;
}

static id hook_navMakeControllerWithContext(id cls, SEL _cmd, id context) {
    NSString *key = WAGRNavHookKey(NSStringFromClass((Class)cls), NSStringFromSelector(_cmd), YES);
    WAGRNavIDCtxIMP orig = NULL;
    NSValue *v = gNavOrig[key];
    if (v) orig = (WAGRNavIDCtxIMP)[v pointerValue];

    id ctx = context ?: WAGRNavCurrentUserContext();
    if (ctx) gNavLastUserContext = ctx;

    id vc = orig ? orig(cls, _cmd, ctx ?: context) : nil;
    WAGRNavInjectUserContextIntoController(vc, ctx);
    NSLog(@"[WATweaks][AuraNav] factory %@ → %@ ctx=%@",
          NSStringFromSelector(_cmd), NSStringFromClass([vc class]), ctx ? @"YES" : @"NO");
    return vc;
}

static void hook_navControllerViewDidLoad(id self, SEL _cmd) {
    id ctx = WAGRNavContextFromController(self);
    WAGRNavInjectUserContextIntoController(self, ctx);

    NSString *key = WAGRNavHookKey(NSStringFromClass([self class]), NSStringFromSelector(_cmd), NO);
    WAGRNavVoidIMP orig = NULL;
    NSValue *v = gNavOrig[key];
    if (v) orig = (WAGRNavVoidIMP)[v pointerValue];
    if (orig) orig(self, _cmd);

    WAGRNavInjectUserContextIntoController(self, ctx);
}

static BOOL WAGRNavHookMessage(NSString *className, NSString *selectorName, BOOL classMethod, IMP replacement) {
    if (!className.length || !selectorName.length || !replacement) return NO;
    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    Class hookClass = classMethod ? object_getClass(cls) : cls;
    if (!hookClass) return NO;

    SEL sel = NSSelectorFromString(selectorName);
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    if (!gNavOrig) gNavOrig = [NSMutableDictionary dictionary];
    if (!gNavHooked) gNavHooked = [NSMutableSet set];

    NSString *key = WAGRNavHookKey(className, selectorName, classMethod);
    if ([gNavHooked containsObject:key]) return YES;

    IMP orig = NULL;
    MSHookMessageEx(hookClass, sel, replacement, &orig);
    if (orig) {
        gNavOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
        [gNavHooked addObject:key];
        gNavFactoryCount++;
        NSLog(@"[WATweaks][AuraNav] hooked %@ %@%@", className, classMethod ? @"+" : @"-", selectorName);
        return YES;
    }
    return NO;
}

extern "C" void WAGRAuraEnsureNavigationHooksInstalled(void) {
    if (!gNavInstalled) {
        gNavInstalled = YES;
        NSLog(@"[WATweaks][AuraNav] navigation owner installed (gating lives in WAGRGateHooks)");
    }

    WAGRNavHookMessage(@"WAAppearanceSettingsViewController", @"initWithContext:", NO, (IMP)hook_navInitWithContext);
    WAGRNavHookMessage(@"WAAppearanceSettingsViewController", @"makeAppIconViewControllerWithContext:", YES, (IMP)hook_navMakeControllerWithContext);
    WAGRNavHookMessage(@"WAAppearanceSettingsViewController", @"makeAppThemeViewControllerWithContext:", YES, (IMP)hook_navMakeControllerWithContext);

    NSArray<NSString *> *controllers = @[
        @"WAAura.AppIconsViewController",
        @"WAAura.AppThemesViewController",
        @"WAAura.RingtonesViewController",
        @"WAAura.AppThemeViewController",
        @"WAAura.AppIconViewController"
    ];
    for (NSString *className in controllers) {
        WAGRNavHookMessage(className, @"viewDidLoad", NO, (IMP)hook_navControllerViewDidLoad);
        WAGRNavHookMessage(className, @"initWithContext:", NO, (IMP)hook_navInitWithContext);
    }
}

// ── Public push helpers ──────────────────────────────────────────────────────
static UIViewController *WAGRNavTopViewControllerFrom(UIViewController *from) {
    UIViewController *top = from;
    if (!top) {
        UIWindow *key = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
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
    WAGRAuraEnsureNavigationHooksInstalled();

    Class settings = NSClassFromString(@"WAAppearanceSettingsViewController");
    SEL sel = NSSelectorFromString(factorySelector);
    if (!settings || ![settings respondsToSelector:sel]) {
        NSLog(@"[WATweaks][AuraNav] factory %@ missing on WAAppearanceSettingsViewController", factorySelector);
        return NO;
    }

    UIViewController *top = WAGRNavTopViewControllerFrom(from);
    id ctx = WAGRNavContextFromController(top);
    if (!ctx) ctx = WAGRNavCurrentUserContext();

    id vc = ((id (*)(id, SEL, id))objc_msgSend)((id)settings, sel, ctx);
    if (![vc isKindOfClass:UIViewController.class]) {
        NSLog(@"[WATweaks][AuraNav] factory %@ did not return UIViewController", factorySelector);
        return NO;
    }

    WAGRNavInjectUserContextIntoController(vc, ctx);

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

extern "C" BOOL WAGRPushAuraThemesVC(UIViewController *from) {
    return WAGRPushAuraFactoryController(from, @"makeAppThemeViewControllerWithContext:");
}

extern "C" BOOL WAGRPushAuraIconsVC(UIViewController *from) {
    return WAGRPushAuraFactoryController(from, @"makeAppIconViewControllerWithContext:");
}

extern "C" BOOL WAGRPushAuraRingtonesVC(UIViewController *from) {
    (void)from;
    // No native WAAppearanceSettings factory for Ringtones confirmed yet.
    // The Settings row path still leads users there normally; this push
    // helper is intentionally inert until a factory is found.
    NSLog(@"[WATweaks][AuraNav] Ringtones direct push disabled — use Settings row instead.");
    return NO;
}

extern "C" BOOL WAGROpenSubscriptionsNative(void) {
    SEL sel = NSSelectorFromString(@"openSettingsAndSubscriptionManagementWithUserInfo:");
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    if (!all) return NO;
    for (unsigned int i = 0; i < n; i++) {
        if (!class_getInstanceMethod(all[i], sel)) continue;
        free(all);
        return YES;
    }
    free(all);
    return NO;
}

// ── Simulation flag + bulk activation ────────────────────────────────────────
extern "C" BOOL WAGRAuraSimulationEnabled(void) {
    return WAGRPref(kWAGRAuraSimulation);
}

static NSArray<NSString *> *WAGRAuraPositiveFlags(void) {
    return @[
        @"aura_enabled", @"aura_settings_row_enabled", @"aura_subscription_simulation_enabled",
        @"aura_logging_enabled",
        @"aura_app_icon_enabled", @"aura_app_icon_benefit_active", @"aura_app_icon_multi_account_support",
        @"aura_app_themes_enabled", @"aura_app_themes_benefit_active",
        @"aura_app_themes_chat_checkmark_themed_enabled", @"aura_app_themes_new_selection_flow_enabled",
        @"aura_app_themes_share_extension_themed_enabled", @"aura_app_themes_status_ring_enabled",
        @"aura_app_themes_illustration_lottie_enabled",
        @"aura_apple_watch_app_theme_enabled", @"aura_apple_watch_app_themes_enabled",
        @"aura_pinned_chats_enabled", @"aura_pinned_chats_benefit_active",
        @"aura_pinned_chats_targeted_nux_force",
        @"aura_enhanced_lists_enabled", @"aura_enhanced_lists_benefit_active",
        @"aura_ringtones_enabled", @"aura_ringtones_benefit_active", @"aura_ringtones_per_chat_enabled",
        @"aura_stickers_enabled", @"aura_stickers_benefit_active",
        @"aura_stickers_overlay_animation_enabled", @"aura_painted_door_stickers_enabled",
        @"ai_subscription_enabled", @"ai_subscription_imagine_intent_enabled",
        @"isExpandedFormattingPlusEnabled", @"isEligibleForSubscriptions",
        @"isAppIconsBenefitActive", @"isAppThemesBenefitActive",
        @"isEnhancedListsBenefitActive", @"isExtendedPinnedChatBenefitActive",
        @"isRingtonesBenefitActive", @"isStickersBenefitActive",
        @"isSubscribedToAiBenefit", @"isAISubscriptionEnabled",
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

extern "C" void WAGRAuraActivateAllFlags(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kWAGRAuraSimulation];
    for (NSString *flag in WAGRAuraPositiveFlags()) WAGRGateSet(flag, YES);
    for (NSString *flag in WAGRAuraNegativeFlags()) WAGRGateSet(flag, NO);
    WAGRGateHooksEnsureInstalled();
    WAGRAuraEnsureNavigationHooksInstalled();
}

extern "C" void WAGRAuraDeactivateAllFlags(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kWAGRAuraSimulation];
    for (NSString *flag in WAGRAuraPositiveFlags()) WAGRGateClear(flag);
    for (NSString *flag in WAGRAuraNegativeFlags()) WAGRGateClear(flag);
}

extern "C" NSString *WAGRAuraNavigationDiagnostic(void) {
    NSUInteger positiveOn = 0;
    for (NSString *flag in WAGRAuraPositiveFlags()) {
        if (WAGRGateIsSet(flag) && WAGRGateGet(flag)) positiveOn++;
    }
    NSUInteger negativeOff = 0;
    for (NSString *flag in WAGRAuraNegativeFlags()) {
        if (WAGRGateIsSet(flag) && !WAGRGateGet(flag)) negativeOff++;
    }
    return [NSString stringWithFormat:
        @"simulation=%@\npositive overrides ON=%lu/%lu\nnegative overrides OFF=%lu/%lu\nfactory hooks=%lu\ncontext fixes=%lu\nlastUserContext=%@\nnative subscriptions opener=%@",
        WAGRAuraSimulationEnabled() ? @"ON" : @"OFF",
        (unsigned long)positiveOn, (unsigned long)WAGRAuraPositiveFlags().count,
        (unsigned long)negativeOff, (unsigned long)WAGRAuraNegativeFlags().count,
        (unsigned long)gNavFactoryCount,
        (unsigned long)gNavContextFixCount,
        gNavLastUserContext ? NSStringFromClass([gNavLastUserContext class]) : @"none",
        WAGROpenSubscriptionsNative() ? @"found" : @"missing"];
}

// ── dyld + constructor ───────────────────────────────────────────────────────
static void WAGRAuraNavDyldCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh; (void)vmaddr_slide;
    dispatch_async(dispatch_get_main_queue(), ^{ WAGRAuraEnsureNavigationHooksInstalled(); });
}

__attribute__((constructor))
static void WAGRAuraNavConstructor(void) {
    @autoreleasepool {
        WAGRAuraEnsureNavigationHooksInstalled();
        _dyld_register_func_for_add_image(WAGRAuraNavDyldCallback);
    }
}
