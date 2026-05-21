// WAGRDebugMenuLauncher.xm
// ─────────────────────────────────────────────────────────────────────────────
// Programmatically opens WhatsApp's native developer menu (WADebugViewController).
//
// Why this exists
// ───────────────
// Hooking the gating selectors (isDebugMenuAllowed / isDebugMenuShortcutEnabled)
// only unlocks the *visibility* of WhatsApp's Settings → Developer row. If
// the user has never tapped that row before, or if WhatsApp's gating logic
// has additional conditions we have not yet hooked, the menu still won't
// open through normal navigation. This file takes a different approach:
// once tapped, it directly instantiates WADebugViewController via its public
// initWithUserContext: initializer and presents it modally — entirely
// bypassing whatever extra gating WhatsApp imposes at the navigation layer.
//
// The userContext lookup
// ──────────────────────
// WADebugViewController needs a WAContextMain instance to initialize. We
// search for one in three places, in order of preference:
//
//   1. The responder chain of the tap origin (cheapest, most likely to hit
//      because the user tapped from a VC that lives inside the WhatsApp
//      window hierarchy). Each step is probed for the `wa_userContext`
//      selector (which WhatsApp adds to many of its VCs via category) and
//      for the `_userContext` ivar (which WASettingsNavigationController
//      and many others declare).
//
//   2. The full UIApplication window tree (slower but exhaustive). Walks
//      every UIWindow → rootViewController → childViewControllers and
//      presentedViewController chain.
//
//   3. Last resort: if we cannot find a userContext but a live
//      WADebugViewController instance already exists somewhere in the
//      tree (because the user opened Settings once before), present
//      that existing instance.
//
// If all three fail, a clear error is returned so the caller can show a
// friendly alert telling the user to open Settings once first.
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../WAGramPrefix.h"

// ── userContext probes ──────────────────────────────────────────────────────
// Two parallel ways to extract the userContext from an arbitrary object.

// Probe via the wa_userContext selector (a WhatsApp category accessor).
static id wagr_probeWAUserContext(id obj) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(@"wa_userContext");
    if (![obj respondsToSelector:sel]) return nil;
    typedef id (*GetUCFn)(id, SEL);
    GetUCFn fn = (GetUCFn)[obj methodForSelector:sel];
    id uc = fn(obj, sel);
    // Verify the returned value looks like a WAContext, not nil or junk.
    if (!uc) return nil;
    NSString *cls = NSStringFromClass([uc class]);
    if (![cls containsString:@"WAContext"] && ![cls containsString:@"Context"]) return nil;
    return uc;
}

// Probe via the _userContext ivar (declared on many WhatsApp NSObject classes).
static id wagr_userContextIvar(id obj) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], "_userContext");
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

// Combined probe — tries both methods on a single object.
static id wagr_probeUserContext(id obj) {
    return wagr_probeWAUserContext(obj) ?: wagr_userContextIvar(obj);
}

// ── Tree walking ────────────────────────────────────────────────────────────

// Recursively walk a UIViewController tree probing for a userContext.
static id wagr_findUserContextInTree(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 20) return nil;

    id uc = wagr_probeUserContext(vc);
    if (uc) return uc;

    // Some VCs expose the userContext via a custom view they own.
    id viewUC = wagr_probeUserContext(vc.viewIfLoaded);
    if (viewUC) return viewUC;

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
    // Also probe the application delegate itself, in case it holds the context.
    id appDel = (id)UIApplication.sharedApplication.delegate;
    return wagr_probeUserContext(appDel);
}

// Walks the tree looking for a live WADebugViewController instance.
static UIViewController *wagr_findLiveDebugVC(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 20) return nil;
    if ([NSStringFromClass(vc.class) isEqualToString:@"WADebugViewController"]) return vc;

    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *f = wagr_findLiveDebugVC(child, depth + 1);
        if (f) return f;
    }
    if (vc.presentedViewController) {
        UIViewController *f = wagr_findLiveDebugVC(vc.presentedViewController, depth + 1);
        if (f) return f;
    }
    return nil;
}

static UIViewController *wagr_findAnyLiveDebugVC(void) {
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        UIViewController *f = wagr_findLiveDebugVC(win.rootViewController, 0);
        if (f) return f;
    }
    return nil;
}

// ── Public API ──────────────────────────────────────────────────────────────

// Returns YES on success, NO on failure. On failure, *outError is populated
// with a description suitable for showing in an alert.
extern "C" BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError) {
    Class debugCls = NSClassFromString(@"WADebugViewController");
    if (!debugCls) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"A classe WADebugViewController não foi encontrada no runtime. "
                                       @"Esta build do WhatsApp pode não conter o menu developer nativo."
        }];
        return NO;
    }

    // ── Step 1: find a userContext via the responder chain of the tap origin.
    id userContext = nil;
    UIResponder *r = fromVC;
    NSInteger chainSteps = 0;
    while (r && !userContext && chainSteps < 30) {
        userContext = wagr_probeUserContext(r);
        r = r.nextResponder;
        chainSteps++;
    }

    // ── Step 2: fall back to the full window tree.
    if (!userContext) userContext = wagr_findUserContextAnywhere();

    UIViewController *vcToPresent = nil;
    BOOL reusingLiveInstance = NO;

    if (userContext) {
        // ── Happy path: instantiate fresh.
        // Prefer initWithUserContext: (the simple form). If the class only
        // declares initAsModalWithUserContext:, use that instead — both have
        // the same single-argument signature.
        SEL initSel = NSSelectorFromString(@"initWithUserContext:");
        id alloc = [debugCls alloc];
        if (![alloc respondsToSelector:initSel]) {
            initSel = NSSelectorFromString(@"initAsModalWithUserContext:");
        }
        if (![alloc respondsToSelector:initSel]) {
            if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"WADebugViewController não expõe um inicializador "
                                           @"reconhecido. Estrutura do app mudou nesta versão."
            }];
            return NO;
        }
        typedef id (*InitFn)(id, SEL, id);
        InitFn fn = (InitFn)[alloc methodForSelector:initSel];
        vcToPresent = (UIViewController *)fn(alloc, initSel, userContext);
        if (!vcToPresent) {
            // Fallback to grabbing a live one.
            vcToPresent = wagr_findAnyLiveDebugVC();
            reusingLiveInstance = (vcToPresent != nil);
        }
    } else {
        // ── Step 3: no userContext, but maybe a live VC is around.
        vcToPresent = wagr_findAnyLiveDebugVC();
        reusingLiveInstance = (vcToPresent != nil);
    }

    if (!vcToPresent) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"Não consegui localizar o WAContextMain neste momento. "
                                       @"Abra Configurações uma vez (toque no ícone de Configurações), "
                                       @"depois volte aqui e tente de novo."
        }];
        return NO;
    }

    // If we're reusing a live instance that already has a parent (e.g. it
    // is sitting inside the existing WASettingsNavigationController as a
    // child), we cannot simply present it again — UIKit forbids presenting a
    // VC that already has a parent. In that case we wrap it in a new nav
    // controller and detach it on present.
    UINavigationController *nav = nil;
    if ([vcToPresent isKindOfClass:UINavigationController.class]) {
        nav = (UINavigationController *)vcToPresent;
    } else if (reusingLiveInstance && vcToPresent.parentViewController) {
        // The live instance is already a child of someone. Take a different
        // route: ask its parent to present it. This avoids the "already has
        // a parent" UIKit assertion.
        UIViewController *parent = vcToPresent.parentViewController;
        UIViewController *topPresenter = parent;
        while (topPresenter.presentedViewController) topPresenter = topPresenter.presentedViewController;
        // We cannot present a child; instead push or wrap. Safer: just wrap
        // a fresh instance — but we already tried and failed. Last try:
        // re-allocate using the parent's userContext if possible.
        id parentCtx = wagr_probeUserContext(parent);
        if (parentCtx) {
            SEL initSel = NSSelectorFromString(@"initWithUserContext:");
            id alloc2 = [debugCls alloc];
            if ([alloc2 respondsToSelector:initSel]) {
                typedef id (*InitFn)(id, SEL, id);
                InitFn fn = (InitFn)[alloc2 methodForSelector:initSel];
                UIViewController *fresh = (UIViewController *)fn(alloc2, initSel, parentCtx);
                if (fresh) {
                    nav = [[UINavigationController alloc] initWithRootViewController:fresh];
                }
            }
        }
        if (!nav) {
            if (outError) *outError = [NSError errorWithDomain:@"WATweaks" code:5 userInfo:@{
                NSLocalizedDescriptionKey: @"A WADebugViewController viva já está ligada à arvore "
                                           @"de Configurações. Feche o sheet do WATweaks e abra "
                                           @"Configurações → Developer diretamente."
            }];
            return NO;
        }
    } else {
        nav = [[UINavigationController alloc] initWithRootViewController:vcToPresent];
    }

    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    // Add a Done button so the user can dismiss.
    if (!vcToPresent.navigationItem.leftBarButtonItem) {
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                              target:vcToPresent
                                                                              action:@selector(dismiss)];
        // Fallback: if WADebugViewController doesn't have -dismiss, use a closure target.
        if (![vcToPresent respondsToSelector:@selector(dismiss)]) {
            done.target = nav;
            done.action = @selector(dismissViewControllerAnimated:completion:);
        }
        vcToPresent.navigationItem.leftBarButtonItem = done;
    }

    UIViewController *presenter = fromVC;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:nav animated:YES completion:nil];

    NSLog(@"[WATweaks][DevMenuLauncher] presented %@ (reused=%@ ctx=%@)",
          NSStringFromClass(vcToPresent.class),
          reusingLiveInstance ? @"YES" : @"NO",
          userContext ? NSStringFromClass([userContext class]) : @"<live>");

    return YES;
}

extern "C" NSString *WAGRDebugMenuLauncherDiagnosticText(void) {
    Class debugCls = NSClassFromString(@"WADebugViewController");
    id liveCtx = wagr_findUserContextAnywhere();
    UIViewController *liveVC = wagr_findAnyLiveDebugVC();
    return [NSString stringWithFormat:
            @"WADebugViewController class: %@\n"
            @"Live userContext located:   %@\n"
            @"Live debug VC in tree:      %@",
            debugCls ? @"found" : @"NOT FOUND",
            liveCtx ? NSStringFromClass([liveCtx class]) : @"not located",
            liveVC ? @"yes" : @"no"];
}
