// WAGRDebugMenuLauncher.xm
// Opens WhatsApp's real native Debug Menu / Private Experimentation UI.
//
// Preferred path is native provider/context:
//   WAContext/userContext -> debugMenuProvider -> debugViewController or
//   presentDebugControllerIfNeeded.
// Fallbacks instantiate WADebugViewController or PrivateExperimentation VC with
// a live userContext only after Settings/app UI exists.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../WAGramPrefix.h"

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern "C" void WAGRNativeDebugActivateSupportGates(void);

static NSError *WAGRError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"WATweaks.NativeDebug" code:code userInfo:@{NSLocalizedDescriptionKey: msg ?: @"erro"}];
}

static UIViewController *WAGRTopFrom(UIViewController *from) {
    UIViewController *top = from;
    if (!top) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow && w.rootViewController) { top = w.rootViewController; break; }
            }
            if (top) break;
        }
    }
    if (!top) top = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).visibleViewController ?: ((UINavigationController *)top).topViewController;
    if ([top isKindOfClass:UITabBarController.class]) {
        top = ((UITabBarController *)top).selectedViewController;
        if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).visibleViewController ?: ((UINavigationController *)top).topViewController;
    }
    return top;
}

static id WAGRCall0(id obj, NSString *selectorName) {
    if (!obj || !selectorName.length) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (__unused NSException *ex) { return nil; }
}

static id WAGRCall1(id obj, NSString *selectorName, id arg) {
    if (!obj || !selectorName.length) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg); }
    @catch (__unused NSException *ex) { return nil; }
}

static BOOL WAGRCallVoid0(id obj, NSString *selectorName) {
    if (!obj || !selectorName.length) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return NO;
    @try { ((void (*)(id, SEL))objc_msgSend)(obj, sel); return YES; }
    @catch (__unused NSException *ex) { return NO; }
}

static id WAGRValueForKeySafe(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *ex) { return nil; }
}

static id WAGRUserContextFromObject(id obj) {
    if (!obj) return nil;
    for (NSString *sel in @[ @"userContext", @"wa_userContext", @"currentUserContext", @"sharedUserContext", @"mainContext", @"context" ]) {
        id ctx = WAGRCall0(obj, sel);
        if (ctx) return ctx;
    }
    for (NSString *key in @[ @"userContext", @"wa_userContext", @"_userContext", @"context" ]) {
        id ctx = WAGRValueForKeySafe(obj, key);
        if (ctx) return ctx;
    }
    Ivar iv = class_getInstanceVariable([obj class], "_userContext");
    if (iv) {
        @try { id ctx = object_getIvar(obj, iv); if (ctx) return ctx; }
        @catch (__unused NSException *ex) {}
    }
    return nil;
}

static id WAGRFindUserContextInVC(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 20) return nil;
    id ctx = WAGRUserContextFromObject(vc);
    if (ctx) return ctx;
    for (UIViewController *child in vc.childViewControllers) {
        ctx = WAGRFindUserContextInVC(child, depth + 1);
        if (ctx) return ctx;
    }
    if (vc.presentedViewController) return WAGRFindUserContextInVC(vc.presentedViewController, depth + 1);
    return nil;
}

static id WAGRFindLiveUserContext(UIViewController *from) {
    id ctx = WAGRFindUserContextInVC(WAGRTopFrom(from), 0);
    if (ctx) return ctx;

    id appDelegate = UIApplication.sharedApplication.delegate;
    ctx = WAGRUserContextFromObject(appDelegate);
    if (ctx) return ctx;

    for (NSString *className in @[ @"WAContextMain", @"WAContext", @"WAServerProperties" ]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *sel in @[ @"sharedInstance", @"sharedContext", @"mainContext", @"defaultContext", @"currentUserContext", @"userContext" ]) {
            ctx = WAGRCall0((id)cls, sel);
            if (ctx) return ctx;
        }
    }
    return nil;
}

static id WAGRDebugProviderFromContext(id ctx) {
    if (!ctx) return nil;
    for (NSString *sel in @[ @"debugMenuProvider", @"debug_menu_provider", @"debugMenuProviding", @"developerMenuProvider" ]) {
        id provider = WAGRCall0(ctx, sel);
        if (provider) return provider;
    }
    for (NSString *key in @[ @"debugMenuProvider", @"debug_menu_provider", @"developerMenuProvider" ]) {
        id provider = WAGRValueForKeySafe(ctx, key);
        if (provider) return provider;
    }
    return nil;
}

static void WAGRPresentController(UIViewController *from, UIViewController *vc) {
    if (!vc) return;
    UIViewController *top = WAGRTopFrom(from);
    if (!top) return;
    UINavigationController *nav = top.navigationController;
    if (nav && ![vc isKindOfClass:UINavigationController.class]) {
        [nav pushViewController:vc animated:YES];
    } else {
        if (![vc isKindOfClass:UINavigationController.class]) {
            UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:vc];
            wrap.modalPresentationStyle = UIModalPresentationFormSheet;
            vc = wrap;
        }
        [top presentViewController:vc animated:YES completion:nil];
    }
}

static UIViewController *WAGRAllocVCWithUserContext(NSString *className, id ctx, BOOL modalPreferred) {
    Class cls = NSClassFromString(className);
    if (!cls || !ctx) return nil;
    id obj = [cls alloc];
    if (!obj) return nil;

    if (modalPreferred) {
        id vc = WAGRCall1(obj, @"initAsModalWithUserContext:", ctx);
        if ([vc isKindOfClass:UIViewController.class]) return vc;
    }
    id vc = WAGRCall1(obj, @"initWithUserContext:", ctx);
    if ([vc isKindOfClass:UIViewController.class]) return vc;
    return nil;
}

static BOOL WAGROpenViaProvider(UIViewController *fromVC, id provider) {
    if (!provider) return NO;
    if (WAGRCallVoid0(provider, @"presentDebugControllerIfNeeded")) return YES;
    id vc = WAGRCall0(provider, @"debugViewController");
    if ([vc isKindOfClass:UIViewController.class]) {
        WAGRPresentController(fromVC, (UIViewController *)vc);
        return YES;
    }
    return NO;
}

extern "C" BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError) {
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRNativeDebugActivateSupportGates();

    id ctx = WAGRFindLiveUserContext(fromVC);
    if (!ctx) {
        if (outError) *outError = WAGRError(10, @"Não achei userContext vivo. Abra Configurações do WhatsApp e tente novamente.");
        return NO;
    }

    id provider = WAGRDebugProviderFromContext(ctx);
    if (WAGROpenViaProvider(fromVC, provider)) return YES;

    UIViewController *debugVC = WAGRAllocVCWithUserContext(@"WADebugViewController", ctx, YES);
    if (debugVC) {
        WAGRPresentController(fromVC, debugVC);
        return YES;
    }

    UIViewController *privateVC = WAGRAllocVCWithUserContext(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController", ctx, NO);
    if (privateVC) {
        WAGRPresentController(fromVC, privateVC);
        return YES;
    }

    if (outError) {
        NSString *msg = [NSString stringWithFormat:@"userContext=%@, provider=%@, WADebugViewController=%@, PrivateExperimentationVC=%@",
                         NSStringFromClass([ctx class]),
                         provider ? NSStringFromClass([provider class]) : @"nil",
                         NSClassFromString(@"WADebugViewController") ? @"loaded" : @"missing",
                         NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController") ? @"loaded" : @"missing"];
        *outError = WAGRError(99, msg);
    }
    return NO;
}

extern "C" BOOL WAGRLaunchNativePrivateExperimentation(UIViewController *fromVC, NSError **outError) {
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRNativeDebugActivateSupportGates();

    id ctx = WAGRFindLiveUserContext(fromVC);
    if (!ctx) {
        if (outError) *outError = WAGRError(20, @"Não achei userContext vivo para Private Experimentation.");
        return NO;
    }
    UIViewController *privateVC = WAGRAllocVCWithUserContext(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController", ctx, NO);
    if (privateVC) {
        WAGRPresentController(fromVC, privateVC);
        return YES;
    }
    if (outError) *outError = WAGRError(21, @"PrivateExperimentationDebugViewController não está carregado ou initWithUserContext: falhou.");
    return NO;
}

extern "C" NSString *WAGRDebugMenuLauncherDiagnosticText(void) {
    id ctx = WAGRFindLiveUserContext(nil);
    id provider = WAGRDebugProviderFromContext(ctx);
    return [NSString stringWithFormat:
            @"DebugMenuProvider class=%@\nWADebugViewController=%@\nPrivateExperimentationVC=%@\nLive userContext=%@\nResolved provider=%@\nRequired gates: debugUI=%@ whatsbroken=%@ privateDev=%@ privateSync=%@ dogfoodNudge=%@ disableExperimental=%@",
            NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider") ? @"loaded" : @"missing",
            NSClassFromString(@"WADebugViewController") ? @"loaded" : @"missing",
            NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController") ? @"loaded" : @"missing",
            ctx ? NSStringFromClass([ctx class]) : @"not found",
            provider ? NSStringFromClass([provider class]) : @"not found",
            (WAGRGateIsSet(@"waios_mc_debug_ui_enabled") && WAGRGateGet(@"waios_mc_debug_ui_enabled")) ? @"ON" : @"system",
            (WAGRGateIsSet(@"whatsbroken_enabled") && WAGRGateGet(@"whatsbroken_enabled")) ? @"ON" : @"system",
            (WAGRGateIsSet(@"private_abprop_for_dev_only") && WAGRGateGet(@"private_abprop_for_dev_only")) ? @"ON" : @"system",
            (WAGRGateIsSet(@"private_experimentation_should_sync") && WAGRGateGet(@"private_experimentation_should_sync")) ? @"ON" : @"system",
            (WAGRGateIsSet(@"dogfooding_nudge_settings_entrypoint_enabled") && WAGRGateGet(@"dogfooding_nudge_settings_entrypoint_enabled")) ? @"ON" : @"system",
            (WAGRGateIsSet(@"serverPropsDisableExperimental") && !WAGRGateGet(@"serverPropsDisableExperimental")) ? @"OFF" : @"system"];
}
