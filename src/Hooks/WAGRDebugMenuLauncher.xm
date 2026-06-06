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

// ── Common helpers ──────────────────────────────────────────────────────────

static id wagr_probeWAUserContext(id obj) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(@"wa_userContext");
    if (![obj respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))[obj methodForSelector:sel];
    id uc = fn(obj, sel);
    if (!uc) return nil;
    NSString *cls = NSStringFromClass([uc class]);
    if (![cls containsString:@"Context"]) return nil;
    return uc;
}

static id wagr_userContextIvar(id obj) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], "_userContext");
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

static id wagr_probeUserContext(id obj) {
    return wagr_probeWAUserContext(obj) ?: wagr_userContextIvar(obj);
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

static UIViewController *wagr_topViewController(void) {
    UIViewController *top = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (win.isKeyWindow) { top = win.rootViewController; break; }
    }
    if (!top) top = UIApplication.sharedApplication.windows.firstObject.rootViewController;
    UIViewController *prev = nil;
    while (top && top != prev) {
        prev = top;
        if (top.presentedViewController) { top = top.presentedViewController; continue; }
        if ([top isKindOfClass:UINavigationController.class]) {
            UIViewController *v = ((UINavigationController *)top).visibleViewController;
            if (v && v != top) { top = v; continue; }
        }
        if ([top isKindOfClass:UITabBarController.class]) {
            UIViewController *v = ((UITabBarController *)top).selectedViewController;
            if (v && v != top) { top = v; continue; }
        }
        break;
    }
    return top;
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

    SEL presentSel = NSSelectorFromString(@"presentDebugControllerIfNeeded");
    if (![provider respondsToSelector:presentSel]) {
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

extern "C" NSString *WAGRCurrentUserContextDiagnostic(void) {
    UIViewController *top = wagr_topViewController();
    id liveCtx = wagr_findUserContextAnywhere();
    return [NSString stringWithFormat:@"UserContext: %@\nTopVC: %@",
            liveCtx ? NSStringFromClass([liveCtx class]) : @"not located",
            top ? NSStringFromClass([top class]) : @"not located"];
}

extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError) {
    UIViewController *presenter = fromVC ?: wagr_topViewController();
    id ctx = wagr_findUserContextAnywhere();
    NSArray<NSString *> *candidates = @[
        @"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController",
        @"WAPrivateExperimentationDebugViewController",
        @"PrivateExperimentationDebugViewController"
    ];

    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        id obj = nil;
        @try {
            SEL initCtx = NSSelectorFromString(@"initWithUserContext:");
            if (ctx && [cls instancesRespondToSelector:initCtx]) {
                obj = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], initCtx, ctx);
            } else {
                obj = [[cls alloc] init];
            }
        } @catch (__unused NSException *ex) { obj = nil; }

        if ([obj isKindOfClass:UIViewController.class] && presenter) {
            UINavigationController *nav = presenter.navigationController;
            if (nav) [nav pushViewController:(UIViewController *)obj animated:YES];
            else {
                UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:(UIViewController *)obj];
                wrap.modalPresentationStyle = UIModalPresentationFormSheet;
                [presenter presentViewController:wrap animated:YES completion:nil];
            }
            return YES;
        }
    }

    NSError *devErr = nil;
    if (WAGRLaunchNativeDeveloperMenu(presenter, &devErr)) return YES;
    if (outError) {
        NSString *msg = [NSString stringWithFormat:@"Private Experimentation controller not found/instantiable. Developer menu fallback: %@", devErr.localizedDescription ?: @"failed"];
        *outError = [NSError errorWithDomain:@"WATweaks" code:1401 userInfo:@{NSLocalizedDescriptionKey: msg}];
    }
    return NO;
}

extern "C" NSString *WAGRDebugMenuLauncherDiagnosticText(void) {
    Class debugCls = NSClassFromString(@"WADebugViewController");
    Class providerCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    id liveCtx = wagr_findUserContextAnywhere();
    return [NSString stringWithFormat:
            @"WADebugViewController:  %@\n"
            @"DebugMenuProvider Swift: %@\n"
            @"Live userContext:        %@",
            debugCls ? @"found" : @"NOT FOUND",
            providerCls ? @"found" : @"NOT FOUND",
            liveCtx ? NSStringFromClass([liveCtx class]) : @"not located"];
}
