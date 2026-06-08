// WAGRAuraNavigationHooks.xm — Aura navigation and bulk-flag helpers.
// Constructor hot path follows Watusi timing: fixed synchronous hook install only.
// No dyld add-image callback, no timed retry, no runtime scan in constructor.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRGateHooksEnsureInstalled(void);
extern "C" BOOL WAGROpenSubscriptionsNative(void);
extern "C" BOOL WAGRAuraSimulationEnabled(void);

static NSMutableDictionary<NSString *, NSValue *> *gNavOrig = nil;
static NSMutableSet<NSString *> *gNavHooked = nil;
static id gNavLastUserContext = nil;
static NSUInteger gNavFactoryCount = 0;
static NSUInteger gNavContextFixCount = 0;
static BOOL gNavInstalled = NO;

typedef id   (*WAGRNavIDCtxIMP)(id, SEL, id);
typedef void (*WAGRNavVoidIMP)(id, SEL);

static NSString *WAGRNavHookKey(NSString *className, NSString *selectorName, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@|%@|%@", className ?: @"", classMethod ? @"class" : @"inst", selectorName ?: @""];
}

static id WAGRNavCurrentUserContext(void) {
    if (gNavLastUserContext) return gNavLastUserContext;
    NSArray<NSString *> *classNames = @[ @"WAServerProperties", @"WAContextMain", @"WAContext" ];
    NSArray<NSString *> *selectors = @[ @"userContext", @"sharedUserContext", @"currentUserContext", @"mainContext", @"sharedContext", @"defaultContext" ];
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selectorName in selectors) {
            SEL sel = NSSelectorFromString(selectorName);
            if (![cls respondsToSelector:sel]) continue;
            id ctx = nil;
            @try { ctx = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel); } @catch (__unused NSException *ex) { ctx = nil; }
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
        @try { cursor = [cursor valueForKey:@"parentViewController"]; } @catch (__unused NSException *ex) { cursor = nil; }
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

static id hook_navInitWithContext(id self, SEL _cmd, id context) {
    NSString *key = WAGRNavHookKey(NSStringFromClass([self class]), NSStringFromSelector(_cmd), NO);
    WAGRNavIDCtxIMP orig = NULL;
    NSValue *v = gNavOrig[key];
    if (v) orig = reinterpret_cast<WAGRNavIDCtxIMP>([v pointerValue]);
    if (context) gNavLastUserContext = context;
    id result = orig ? orig(self, _cmd, context) : self;
    if (context) WAGRNavInjectUserContextIntoController(result, context);
    return result;
}

static id hook_navMakeControllerWithContext(id cls, SEL _cmd, id context) {
    NSString *key = WAGRNavHookKey(NSStringFromClass((Class)cls), NSStringFromSelector(_cmd), YES);
    WAGRNavIDCtxIMP orig = NULL;
    NSValue *v = gNavOrig[key];
    if (v) orig = reinterpret_cast<WAGRNavIDCtxIMP>([v pointerValue]);
    id ctx = context ?: WAGRNavCurrentUserContext();
    if (ctx) gNavLastUserContext = ctx;
    id vc = orig ? orig(cls, _cmd, ctx ?: context) : nil;
    WAGRNavInjectUserContextIntoController(vc, ctx);
    return vc;
}

static void hook_navControllerViewDidLoad(id self, SEL _cmd) {
    id ctx = WAGRNavContextFromController(self);
    WAGRNavInjectUserContextIntoController(self, ctx);
    NSString *key = WAGRNavHookKey(NSStringFromClass([self class]), NSStringFromSelector(_cmd), NO);
    WAGRNavVoidIMP orig = NULL;
    NSValue *v = gNavOrig[key];
    if (v) orig = reinterpret_cast<WAGRNavVoidIMP>([v pointerValue]);
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
    if (!orig) return NO;
    gNavOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    [gNavHooked addObject:key];
    gNavFactoryCount++;
    return YES;
}

extern "C" void WAGRAuraEnsureNavigationHooksInstalled(void) {
    if (!gNavInstalled) {
        gNavInstalled = YES;
        NSLog(@"[WATweaks][AuraNav] navigation owner installed (no dyld retry)");
    }
    WAGRNavHookMessage(@"WAAppearanceSettingsViewController", @"initWithContext:", NO, (IMP)hook_navInitWithContext);
    WAGRNavHookMessage(@"WAAppearanceSettingsViewController", @"makeAppIconViewControllerWithContext:", YES, (IMP)hook_navMakeControllerWithContext);
    WAGRNavHookMessage(@"WAAppearanceSettingsViewController", @"makeAppThemeViewControllerWithContext:", YES, (IMP)hook_navMakeControllerWithContext);
    for (NSString *className in @[ @"WAAura.AppIconsViewController", @"WAAura.AppThemesViewController", @"WAAura.RingtonesViewController", @"WAAura.AppThemeViewController", @"WAAura.AppIconViewController" ]) {
        WAGRNavHookMessage(className, @"viewDidLoad", NO, (IMP)hook_navControllerViewDidLoad);
        WAGRNavHookMessage(className, @"initWithContext:", NO, (IMP)hook_navInitWithContext);
    }
}

static UIViewController *WAGRNavTopViewControllerFrom(UIViewController *from) {
    UIViewController *top = from;
    if (!top) {
        UIWindow *key = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (w.isKeyWindow) { key = w; break; } }
            if (key) break;
        }
        top = key.rootViewController;
    }
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).topViewController;
    else if ([top isKindOfClass:UITabBarController.class]) {
        top = ((UITabBarController *)top).selectedViewController;
        if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).topViewController;
    }
    return top;
}

static BOOL WAGRPushAuraFactoryController(UIViewController *from, NSString *factorySelector) {
    WAGRAuraEnsureNavigationHooksInstalled();
    Class settings = NSClassFromString(@"WAAppearanceSettingsViewController");
    SEL sel = NSSelectorFromString(factorySelector);
    if (!settings || ![settings respondsToSelector:sel]) return NO;
    UIViewController *top = WAGRNavTopViewControllerFrom(from);
    id ctx = WAGRNavContextFromController(top) ?: WAGRNavCurrentUserContext();
    id vc = ((id (*)(id, SEL, id))objc_msgSend)((id)settings, sel, ctx);
    if (![vc isKindOfClass:UIViewController.class]) return NO;
    WAGRNavInjectUserContextIntoController(vc, ctx);
    UINavigationController *nav = top.navigationController;
    if (nav) [nav pushViewController:(UIViewController *)vc animated:YES];
    else {
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
        wrap.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:wrap animated:YES completion:nil];
    }
    return YES;
}

extern "C" BOOL WAGRPushAuraThemesVC(UIViewController *from) { return WAGRPushAuraFactoryController(from, @"makeAppThemeViewControllerWithContext:"); }
extern "C" BOOL WAGRPushAuraIconsVC(UIViewController *from) { return WAGRPushAuraFactoryController(from, @"makeAppIconViewControllerWithContext:"); }
extern "C" BOOL WAGRPushAuraRingtonesVC(UIViewController *from) { (void)from; return NO; }

static NSArray<NSString *> *WAGRAuraPositiveFlags(void) {
    return @[ @"aura_enabled", @"aura_settings_row_enabled", @"aura_subscription_simulation_enabled", @"aura_logging_enabled", @"aura_app_icon_enabled", @"aura_app_icon_benefit_active", @"aura_app_icon_multi_account_support", @"aura_app_themes_enabled", @"aura_app_themes_benefit_active", @"aura_app_themes_chat_checkmark_themed_enabled", @"aura_app_themes_new_selection_flow_enabled", @"aura_app_themes_share_extension_themed_enabled", @"aura_app_themes_status_ring_enabled", @"aura_app_themes_illustration_lottie_enabled", @"aura_apple_watch_app_theme_enabled", @"aura_apple_watch_app_themes_enabled", @"aura_pinned_chats_enabled", @"aura_pinned_chats_benefit_active", @"aura_pinned_chats_targeted_nux_force", @"aura_enhanced_lists_enabled", @"aura_enhanced_lists_benefit_active", @"aura_ringtones_enabled", @"aura_ringtones_benefit_active", @"aura_ringtones_per_chat_enabled", @"aura_stickers_enabled", @"aura_stickers_benefit_active", @"aura_stickers_overlay_animation_enabled", @"aura_painted_door_stickers_enabled", @"ai_subscription_enabled", @"ai_subscription_imagine_intent_enabled", @"isExpandedFormattingPlusEnabled", @"isEligibleForSubscriptions", @"isAppIconsBenefitActive", @"isAppThemesBenefitActive", @"isEnhancedListsBenefitActive", @"isExtendedPinnedChatBenefitActive", @"isRingtonesBenefitActive", @"isStickersBenefitActive", @"isSubscribedToAiBenefit", @"isAISubscriptionEnabled", @"wa_subscriptions_entry_point_settings_enabled", @"wa_subscriptions_settings_green_dot_enabled", @"premium_blue_enabled" ];
}

static NSArray<NSString *> *WAGRAuraNegativeFlags(void) {
    return @[ @"aura_kill_switch", @"aura_premium_stickers_killswitch", @"aura_stickers_old_client_block_enabled" ];
}

extern "C" void WAGRAuraActivateAllFlags(void) {
    WAGRGateSet(kWAGRAuraSimulation, YES);
    for (NSString *flag in WAGRAuraPositiveFlags()) WAGRGateSet(flag, YES);
    for (NSString *flag in WAGRAuraNegativeFlags()) WAGRGateSet(flag, NO);
    WAGRGateHooksEnsureInstalled();
    WAGRAuraEnsureNavigationHooksInstalled();
}

extern "C" void WAGRAuraDeactivateAllFlags(void) {
    WAGRGateClear(kWAGRAuraSimulation);
    for (NSString *flag in WAGRAuraPositiveFlags()) WAGRGateClear(flag);
    for (NSString *flag in WAGRAuraNegativeFlags()) WAGRGateClear(flag);
}

extern "C" NSString *WAGRAuraNavigationDiagnostic(void) {
    NSUInteger positiveOn = 0;
    for (NSString *flag in WAGRAuraPositiveFlags()) if (WAGRGateIsSet(flag) && WAGRGateGet(flag)) positiveOn++;
    NSUInteger negativeOff = 0;
    for (NSString *flag in WAGRAuraNegativeFlags()) if (WAGRGateIsSet(flag) && !WAGRGateGet(flag)) negativeOff++;
    return [NSString stringWithFormat:@"simulation=%@\npositive overrides ON=%lu/%lu\nnegative overrides OFF=%lu/%lu\nfactory hooks=%lu\ncontext fixes=%lu\nlastUserContext=%@\nnative subscriptions opener=%@", WAGRAuraSimulationEnabled() ? @"ON" : @"OFF", (unsigned long)positiveOn, (unsigned long)WAGRAuraPositiveFlags().count, (unsigned long)negativeOff, (unsigned long)WAGRAuraNegativeFlags().count, (unsigned long)gNavFactoryCount, (unsigned long)gNavContextFixCount, gNavLastUserContext ? NSStringFromClass([gNavLastUserContext class]) : @"none", WAGROpenSubscriptionsNative() ? @"found" : @"missing"];
}

// startup is coordinated by WAGRBootstrap.xm
static void WAGRAuraNavConstructor(void) {
    @autoreleasepool {
        WAGRAuraEnsureNavigationHooksInstalled();
    }
}
