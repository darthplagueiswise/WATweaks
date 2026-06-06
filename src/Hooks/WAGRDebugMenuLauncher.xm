// WAGRDebugMenuLauncher.xm
// ─────────────────────────────────────────────────────────────────────────────
// Opens WhatsApp's native developer menu. Goes through three strategies in
// preference order — the earlier ones are closer to WhatsApp's intended
// path, so the menu's cells end up fully clickable; only the last resort
// instantiates the controller fresh (which leaves some cell taps inert
// because the surrounding Swift environment is not fully wired).
//
// Strategy 1 — DebugMenuProvider.presentDebugControllerIfNeeded
//    The category WADebugMenuMain on _TtC15WADebugMenuMain17DebugMenuProvider
//    adds the method -presentDebugControllerIfNeeded. That method is what
//    the app itself calls when it decides to surface the dev menu. We try
//    to obtain a DebugMenuProvider instance through WAContextMain
//    (which is the dependency container) and invoke that method. When this
//    works, every cell in the menu is fully functional because we used
//    WhatsApp's intended entry point.
//
// Strategy 2 — Navigate to Settings tab and reveal the Developer row
//    If we cannot reach a DebugMenuProvider singleton, we instead switch
//    the tab bar controller to the Settings tab, pop to the Settings root,
//    and scroll the table so the Developer row is on-screen. The user then
//    taps it themselves; WhatsApp handles the navigation natively, again
//    keeping every internal cell functional.
//
// Strategy 3 — Instantiate WADebugViewController fresh (last resort)
//    The legacy strategy from the previous WATweaks release. Works enough
//    to display the screen but leaves several internal cells inert because
//    the Swift environment around the controller is not fully wired. Kept
//    as a final fallback so a user with no other recourse still gets *some*
//    view of the menu.
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRLog.h"

extern "C" void WAGRContextSpyInstallForContext(id ctx);
extern "C" void WAGRPrivateExpDumpDynamicFields(id instance, NSString *stage);
extern "C" void WAGRPrivateExpKickManagerIfAvailable(id instance);

// ── Real userContext cache ──────────────────────────────────────────────────
// The real context is the object WhatsApp passes into WADebugViewController
// -initWithUserContext: and later exposes through -userContext. Do not use a
// guessed WAContextMain singleton when this exists: the PrivateExperimentation
// manager needs the same account/session-bound userContext or its ivars remain nil.
static id gWAGRLastUserContext = nil;
static NSString *gWAGRLastUserContextSource = nil;

extern "C" void WAGRRememberUserContext(id ctx, NSString *source) {
    if (!ctx) return;
    NSString *cls = NSStringFromClass([ctx class]);
    if (![cls containsString:@"Context"] && ![cls containsString:@"User"]) {
        // Be conservative, but do not reject Swift context classes with long names.
        if (![cls containsString:@"WA"]) return;
    }
    gWAGRLastUserContext = ctx;
    gWAGRLastUserContextSource = [source copy] ?: @"unknown";
    WAGRLogAppendF(@"[UserContext] cached %@ from %@", cls, gWAGRLastUserContextSource);
    WAGRContextSpyInstallForContext(ctx);
}

extern "C" id WAGRCurrentUserContext(void) {
    return gWAGRLastUserContext;
}

extern "C" NSString *WAGRCurrentUserContextDiagnostic(void) {
    return [NSString stringWithFormat:@"cached=%@\nsource=%@",
            gWAGRLastUserContext ? NSStringFromClass([gWAGRLastUserContext class]) : @"nil",
            gWAGRLastUserContextSource ?: @"none"];
}

// ── Common helpers ──────────────────────────────────────────────────────────

static id wagr_callNoArgObject(id obj, NSString *selectorName) {
    if (!obj || !selectorName.length) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return nil;
    id value = nil;
    @try {
        id (*fn)(id, SEL) = (id (*)(id, SEL))[obj methodForSelector:sel];
        value = fn(obj, sel);
    } @catch (__unused NSException *ex) { value = nil; }
    return value;
}

static BOOL wagr_looksLikeUserContext(id uc) {
    if (!uc) return NO;
    NSString *cls = NSStringFromClass([uc class]);
    if ([cls containsString:@"UserContext"] || [cls containsString:@"WAUserContext"] ||
        [cls containsString:@"ContextMain"] || [cls isEqualToString:@"WAContext"] ||
        [cls containsString:@"WAContext"]) return YES;
    // A real WhatsApp userContext usually exposes abProperties/debugPropOverrides.
    if ([uc respondsToSelector:NSSelectorFromString(@"abProperties")]) return YES;
    if ([uc respondsToSelector:NSSelectorFromString(@"debugPropOverrides")]) return YES;
    return NO;
}

static id wagr_userContextIvar(id obj) {
    if (!obj) return nil;
    for (NSString *ivarName in @[@"_userContext", @"userContext"]) {
        Ivar iv = class_getInstanceVariable([obj class], ivarName.UTF8String);
        if (!iv) continue;
        id value = nil;
        @try { value = object_getIvar(obj, iv); } @catch (__unused NSException *ex) { value = nil; }
        if (wagr_looksLikeUserContext(value)) return value;
    }
    return nil;
}

static id wagr_probeUserContext(id obj) {
    if (!obj) return nil;
    for (NSString *selName in @[@"userContext", @"wa_userContext", @"currentUserContext", @"sharedUserContext", @"mainContext", @"sharedContext", @"context"]) {
        id uc = wagr_callNoArgObject(obj, selName);
        if (wagr_looksLikeUserContext(uc)) {
            WAGRRememberUserContext(uc, [NSString stringWithFormat:@"%@.%@", NSStringFromClass([obj class]), selName]);
            return uc;
        }
    }
    id iv = wagr_userContextIvar(obj);
    if (wagr_looksLikeUserContext(iv)) {
        WAGRRememberUserContext(iv, [NSString stringWithFormat:@"%@._userContext", NSStringFromClass([obj class])]);
        return iv;
    }
    @try {
        id kvc = [obj valueForKey:@"userContext"];
        if (wagr_looksLikeUserContext(kvc)) {
            WAGRRememberUserContext(kvc, [NSString stringWithFormat:@"%@ KVC userContext", NSStringFromClass([obj class])]);
            return kvc;
        }
    } @catch (__unused NSException *ex) {}
    return nil;
}

static id wagr_findUserContextInTree(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 20) return nil;
    id uc = wagr_probeUserContext(vc);
    if (uc) return uc;
    for (UIViewController *child in vc.childViewControllers) {
        uc = wagr_findUserContextInTree(child, depth + 1);
        if (uc) return uc;
    }
    if (vc.presentedViewController) {
        uc = wagr_findUserContextInTree(vc.presentedViewController, depth + 1);
        if (uc) return uc;
    }
    return nil;
}

static id wagr_findUserContextAnywhere(void) {
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        id uc = wagr_findUserContextInTree(win.rootViewController, 0);
        if (uc) return uc;
    }
    id appDel = (id)UIApplication.sharedApplication.delegate;
    return wagr_probeUserContext(appDel);
}

// ── Strategy 1: DebugMenuProvider.presentDebugControllerIfNeeded ───────────
// Tries to obtain a DebugMenuProvider instance and invoke its native
// presentation method. The method is part of the WADebugMenuMain category,
// confirmed via static analysis of __objc_catlist.
static BOOL wagr_strategy1_presentViaProvider(NSError **outError) {
    id ctx = wagr_findUserContextAnywhere();
    if (!ctx) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:11
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                                @"strategy1: no userContext"}];
        return NO;
    }

    // Try the common property names a dependency-container exposes.
    // WhatsApp uses several conventions, so we sweep a small list.
    NSArray *providerKeys = @[@"debugMenuProvider",
                              @"debug_menu_provider",
                              @"debugMenuProviding",
                              @"developerMenuProvider"];
    id provider = nil;
    for (NSString *k in providerKeys) {
        SEL sel = NSSelectorFromString(k);
        if (![ctx respondsToSelector:sel]) continue;
        id (*fn)(id, SEL) = (id (*)(id, SEL))[ctx methodForSelector:sel];
        provider = fn(ctx, sel);
        if (provider) break;
    }

    // Fall back to KVC if no direct accessor was found — WAContext implements
    // dynamic property lookup for its registered services.
    if (!provider) {
        @try { provider = [ctx valueForKey:@"debugMenuProvider"]; }
        @catch (__unused id e) { provider = nil; }
    }

    if (!provider) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:12
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                                @"strategy1: provider not in context"}];
        return NO;
    }

    // Prefer the provider's already-wired Debug VC when available; it is the
    // best source for the real userContext used by WhatsApp internally.
    id debugVC = wagr_callNoArgObject(provider, @"debugViewController");
    id debugCtx = wagr_probeUserContext(debugVC);
    if (debugCtx) WAGRRememberUserContext(debugCtx, @"DebugMenuProvider.debugViewController.userContext");

    SEL presentSel = NSSelectorFromString(@"presentDebugControllerIfNeeded");
    if (![provider respondsToSelector:presentSel]) {
        if (debugVC && [debugVC isKindOfClass:UIViewController.class]) {
            UIViewController *top = nil;
            for (UIWindow *win in UIApplication.sharedApplication.windows) {
                if (win.isKeyWindow) { top = win.rootViewController; break; }
            }
            while (top.presentedViewController) top = top.presentedViewController;
            if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).visibleViewController;
            [(UIViewController *)top presentViewController:(UIViewController *)debugVC animated:YES completion:nil];
            return YES;
        }
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:13
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                                @"strategy1: provider lacks presentDebugControllerIfNeeded"}];
        return NO;
    }

    void (*fn)(id, SEL) = (void (*)(id, SEL))[provider methodForSelector:presentSel];
    fn(provider, presentSel);
    NSLog(@"[WATweaks][Launcher] strategy1: presented via DebugMenuProvider");
    return YES;
}

// ── Strategy 2: switch to Settings tab and reveal Developer row ─────────────
// Bring the user to where the Developer row already exists, then scroll it
// into view. The user taps it themselves; WhatsApp handles the rest. This
// is more reliable than instantiating the controller because every cell
// inside is wired by WhatsApp's normal navigation flow.
static UITabBarController *wagr_findTabBarController(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 20) return nil;
    if ([vc isKindOfClass:UITabBarController.class]) return (UITabBarController *)vc;
    for (UIViewController *child in vc.childViewControllers) {
        UITabBarController *t = wagr_findTabBarController(child, depth + 1);
        if (t) return t;
    }
    if (vc.presentedViewController) {
        return wagr_findTabBarController(vc.presentedViewController, depth + 1);
    }
    return nil;
}

static UITableViewCell *wagr_findDeveloperCell(UITableView *tv) {
    if (!tv) return nil;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            UITableViewCell *c = [tv cellForRowAtIndexPath:ip];
            NSString *text = c.textLabel.text.lowercaseString ?: @"";
            if ([text containsString:@"developer"] || [text containsString:@"desenvolvedor"]) {
                return c;
            }
        }
    }
    return nil;
}

static BOOL wagr_strategy2_revealInSettings(NSError **outError) {
    // Find the tab bar controller.
    UITabBarController *tab = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        tab = wagr_findTabBarController(win.rootViewController, 0);
        if (tab) break;
    }
    if (!tab) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:21
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                                @"strategy2: tab bar not found"}];
        return NO;
    }

    // Find the Settings tab by class name — its root VC is typically a
    // WASettingsNavigationController (per the user's runtime browser screen).
    NSInteger settingsIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)tab.viewControllers.count; i++) {
        UIViewController *root = tab.viewControllers[i];
        NSString *cls = NSStringFromClass(root.class);
        if ([cls containsString:@"Settings"]) { settingsIdx = i; break; }
        if ([root isKindOfClass:UINavigationController.class]) {
            UIViewController *r = ((UINavigationController *)root).viewControllers.firstObject;
            NSString *cr = NSStringFromClass(r.class);
            if ([cr containsString:@"Settings"]) { settingsIdx = i; break; }
        }
    }
    if (settingsIdx < 0) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:22
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                                @"strategy2: settings tab not found"}];
        return NO;
    }

    tab.selectedIndex = (NSUInteger)settingsIdx;

    // Schedule a small delay so the tab transition completes before we
    // look for the Developer row.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *root = tab.selectedViewController;
        if ([root isKindOfClass:UINavigationController.class]) {
            UINavigationController *nav = (UINavigationController *)root;
            [nav popToRootViewControllerAnimated:NO];
            UIViewController *visible = nav.viewControllers.firstObject;
            // Find a table view in the visible VC.
            UITableView *tv = nil;
            if ([visible respondsToSelector:@selector(tableView)]) {
                id maybe = ((id (*)(id, SEL))objc_msgSend)(visible, @selector(tableView));
                if ([maybe isKindOfClass:UITableView.class]) tv = maybe;
            }
            if (!tv) {
                for (UIView *sub in visible.view.subviews) {
                    if ([sub isKindOfClass:UITableView.class]) { tv = (UITableView *)sub; break; }
                }
            }
            UITableViewCell *cell = wagr_findDeveloperCell(tv);
            if (cell) {
                NSIndexPath *ip = [tv indexPathForCell:cell];
                if (ip) {
                    [tv scrollToRowAtIndexPath:ip
                              atScrollPosition:UITableViewScrollPositionMiddle
                                      animated:YES];
                }
            }
        }
    });

    NSLog(@"[WATweaks][Launcher] strategy2: switched to Settings, revealing Developer row");
    return YES;
}

// ── Strategy 3: instantiate fresh (legacy) ──────────────────────────────────
// Same logic the previous version used. Kept as last resort.
static BOOL wagr_strategy3_instantiateFresh(UIViewController *fromVC, NSError **outError) {
    (void)fromVC;
    if (outError) {
        *outError = [NSError errorWithDomain:@"WATweaks" code:39
                                    userInfo:@{NSLocalizedDescriptionKey:
                                                   @"strategy3 disabled: raw WADebugViewController alloc/init can trigger Swift runtime traps on close. Use provider/settings reveal path or Debug VC Lab diagnostics."}];
    }
    return NO;
}

// ── Public API ──────────────────────────────────────────────────────────────
extern "C" BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError) {
    NSError *e1 = nil;
    if (wagr_strategy1_presentViaProvider(&e1)) return YES;

    NSError *e2 = nil;
    if (wagr_strategy2_revealInSettings(&e2)) return YES;

    NSError *e3 = nil;
    if (wagr_strategy3_instantiateFresh(fromVC, &e3)) return YES;

    if (outError) {
        NSString *combined = [NSString stringWithFormat:
            @"Todas as três estratégias falharam.\n\n"
             "1. %@\n2. %@\n3. %@",
            e1.localizedDescription ?: @"?",
            e2.localizedDescription ?: @"?",
            e3.localizedDescription ?: @"?"];
        *outError = [NSError errorWithDomain:@"WATweaks" code:99
                                    userInfo:@{NSLocalizedDescriptionKey: combined}];
    }
    return NO;
}



static id wagr_preflightCallObject(id obj, NSString *selectorName, BOOL *respondsOut) {
    if (respondsOut) *respondsOut = NO;
    if (!obj || !selectorName.length) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return nil;
    if (respondsOut) *respondsOut = YES;
    id ret = nil;
    @try {
        id (*fn)(id, SEL) = (id (*)(id, SEL))[obj methodForSelector:sel];
        ret = fn(obj, sel);
    } @catch (__unused NSException *ex) { ret = nil; }
    return ret;
}

static BOOL wagr_preflightCallBool(id obj, NSString *selectorName, BOOL *respondsOut) {
    if (respondsOut) *respondsOut = NO;
    if (!obj || !selectorName.length) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return NO;
    if (respondsOut) *respondsOut = YES;
    BOOL ret = NO;
    @try {
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))[obj methodForSelector:sel];
        ret = fn(obj, sel);
    } @catch (__unused NSException *ex) { ret = NO; }
    return ret;
}


static NSArray<NSString *> *wagr_privateExpPositiveGateKeys(void) {
    return @[
        @"isDebugMenuAllowed",
        @"isDebugMenuShortcutEnabled",
        @"waios_mc_debug_ui_enabled",
        @"whatsbroken_enabled",
        @"private_abprop_for_dev_only",
        @"private_experimentation_should_sync",
        @"private_experimentation_use_acs_config_id",
        @"dogfooding_nudge_settings_entrypoint_enabled",
        @"dogfooding_nudge_banner_home_screen_enabled",
        @"username_dogfooding_pn_privacy_enabled",
        @"give_dogfooders_task_id_for_bug_reporting",
        @"groups_member_recommendations_debug_ui",
        @"is_internal",
        @"is_internal_tester",
        @"_is_employee",
        @"wamo_is_employee",
        @"ig_fb_dogfooder",
        @"hn_dogfooding",
        @"malibu_dogfooding"
    ];
}

static NSArray<NSString *> *wagr_privateExpNegativeGateKeys(void) {
    return @[
        @"serverPropsDisableExperimental",
        @"graphQLEmployeeC1Disabled",
        @"ios_contact_suggestions_internal_tool_exclude_employees_enabled"
    ];
}

static void wagr_bootstrapPrivateExpInternalGates(void) {
    for (NSString *key in wagr_privateExpPositiveGateKeys()) WAGRGateSet(key, YES);
    for (NSString *key in wagr_privateExpNegativeGateKeys()) WAGRGateSet(key, NO);
    WAGRLogAppendF(@"[PrivateExp][Gates] bootstrapped positive=%lu negative=%lu",
                   (unsigned long)wagr_privateExpPositiveGateKeys().count,
                   (unsigned long)wagr_privateExpNegativeGateKeys().count);
}

static void wagr_privateExpPreflight(id ctx) {
    if (!ctx) {
        WAGRLogAppend(@"[PreFlight] ctx=nil");
        return;
    }

    WAGRLogAppendF(@"[PreFlight] ctx=%@ (%p)", NSStringFromClass([ctx class]), (__bridge void *)ctx);

    NSArray<NSString *> *objSelectors = @[
        @"privateABProperties", @"debugPropOverrides", @"abProperties",
        @"preferences", @"preferencesStore", @"accountProvider",
        @"mobileConfig", @"mobileConfigManager"
    ];
    for (NSString *sel in objSelectors) {
        BOOL responds = NO;
        id ret = wagr_preflightCallObject(ctx, sel, &responds);
        WAGRLogAppendF(@"[PreFlight] ctx.%@ responds=%@ -> %@ (%p)",
                       sel, responds ? @"YES" : @"NO",
                       ret ? NSStringFromClass([ret class]) : @"nil", (__bridge void *)ret);
    }

    for (NSString *sel in @[@"isPrimaryDevice", @"isInternalUser", @"isEmployee", @"isMetaEmployeeOrInternalTester"]) {
        BOOL responds = NO;
        BOOL ret = wagr_preflightCallBool(ctx, sel, &responds);
        WAGRLogAppendF(@"[PreFlight] ctx.%@ responds=%@ -> %@",
                       sel, responds ? @"YES" : @"NO", ret ? @"YES" : @"NO");
    }

    BOOL apResponds = NO;
    id accountProvider = wagr_preflightCallObject(ctx, @"accountProvider", &apResponds);
    if (accountProvider) {
        WAGRLogAppendF(@"[PreFlight] accountProvider=%@ (%p)", NSStringFromClass([accountProvider class]), (__bridge void *)accountProvider);
        for (NSString *sel in @[@"isPrimaryDevice", @"isInternalUser", @"isEmployee", @"isMetaEmployeeOrInternalTester"]) {
            BOOL responds = NO;
            BOOL ret = wagr_preflightCallBool(accountProvider, sel, &responds);
            WAGRLogAppendF(@"[PreFlight] accountProvider.%@ responds=%@ -> %@",
                           sel, responds ? @"YES" : @"NO", ret ? @"YES" : @"NO");
        }
    }
}

static UIViewController *wagr_topPresenter(UIViewController *fromVC) {
    UIViewController *top = fromVC;
    if (!top) {
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.isKeyWindow) { top = win.rootViewController; break; }
        }
    }
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).visibleViewController;
    if ([top isKindOfClass:UITabBarController.class]) top = ((UITabBarController *)top).selectedViewController;
    return top;
}

extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError) {
    WAGRLogAppend(@"[PrivateExp] launch requested");
    id ctx = WAGRCurrentUserContext() ?: wagr_findUserContextAnywhere();
    if (!ctx) {
        WAGRLogAppend(@"[PrivateExp] failed: no real userContext cached/found");
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:51 userInfo:@{NSLocalizedDescriptionKey:@"PrivateExperimentation: não achei userContext real. Abra o Developer nativo primeiro e tente novamente."}];
        return NO;
    }

    Class cls = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
    if (!cls) cls = NSClassFromString(@"WAPrivateExperimentation.PrivateExperimentationDebugViewController");
    if (!cls) {
        WAGRLogAppend(@"[PrivateExp] failed: PrivateExperimentationDebugViewController class not loaded");
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:52 userInfo:@{NSLocalizedDescriptionKey:@"PrivateExperimentationDebugViewController não carregou."}];
        return NO;
    }

    SEL initSel = NSSelectorFromString(@"initWithUserContext:");
    if (![cls instancesRespondToSelector:initSel]) {
        WAGRLogAppend(@"[PrivateExp] failed: VC does not respond to initWithUserContext:");
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:53 userInfo:@{NSLocalizedDescriptionKey:@"PrivateExperimentationDebugViewController não responde initWithUserContext:."}];
        return NO;
    }

    wagr_bootstrapPrivateExpInternalGates();
    WAGRLogAppendF(@"[PrivateExp] opening with ctx=%@ (%p)", NSStringFromClass([ctx class]), (__bridge void *)ctx);
    wagr_privateExpPreflight(ctx);
    id vc = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], initSel, ctx);
    if (![vc isKindOfClass:UIViewController.class]) {
        WAGRLogAppendF(@"[PrivateExp] failed: init returned %@", vc ? NSStringFromClass([vc class]) : @"nil");
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:54 userInfo:@{NSLocalizedDescriptionKey:@"initWithUserContext: não retornou UIViewController."}];
        return NO;
    }

    WAGRPrivateExpDumpDynamicFields(vc, @"after launcher init");
    WAGRLogAppend(@"[PrivateExp] manager kick deferred to PrivateExpVC viewDidAppear");

    UIViewController *top = wagr_topPresenter(fromVC);
    UINavigationController *nav = top.navigationController;
    if (nav) [nav pushViewController:(UIViewController *)vc animated:YES];
    else {
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
        wrap.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:wrap animated:YES completion:nil];
    }
    WAGRLogAppendF(@"[PrivateExp] presented %@", NSStringFromClass([vc class]));
    return YES;
}

extern "C" NSString *WAGRDebugMenuLauncherDiagnosticText(void) {
    Class debugCls = NSClassFromString(@"WADebugViewController");
    Class providerCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    id liveCtx = wagr_findUserContextAnywhere();
    return [NSString stringWithFormat:
            @"WADebugViewController:  %@\n"
            @"DebugMenuProvider Swift: %@\n"
            @"Live userContext:        %@\n"
            @"Cached userContext:\n%@",
            debugCls ? @"found" : @"NOT FOUND",
            providerCls ? @"found" : @"NOT FOUND",
            liveCtx ? NSStringFromClass([liveCtx class]) : @"not located",
            WAGRCurrentUserContextDiagnostic() ?: @"n/a"];
}
