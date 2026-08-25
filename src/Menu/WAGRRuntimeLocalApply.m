#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

// Local Apply bridge for the runtime editors.
//
// WAGRMainSettingsVC historically reapplied GateStore/WAAB central hooks, while
// ABPropsBrowserVC and SurfaceBrowserVC persist their exact typed overrides in
// WAGRRuntimeValueStore.  Keep those stores independent, but make every Apply
// entry point explicitly reinstall the runtime-value hooks as well.
//
// This file intentionally does not touch the cell renderer or value semantics.
// It only wires navigation buttons and the exact persisted-hook reinstall path.

static const void *kWAGRABLocalApplyButtonKey = &kWAGRABLocalApplyButtonKey;
static const void *kWAGRSurfaceLocalApplyButtonKey = &kWAGRSurfaceLocalApplyButtonKey;

static void (*gWAGRABOriginalViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*gWAGRSurfaceOriginalViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*gWAGRMainOriginalApplyAllHooks)(id, SEL) = NULL;

static BOOL gWAGRABViewHookInstalled = NO;
static BOOL gWAGRSurfaceViewHookInstalled = NO;
static BOOL gWAGRMainApplyHookInstalled = NO;

static id WAGRLocalApplyKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRLocalApplyRefresh(id controller) {
    SEL selector = NSSelectorFromString(@"applyCurrentFilter");
    if (![controller respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(controller, selector); }
    @catch (__unused NSException *exception) {}
}

static void WAGRLocalApplyPresent(UIViewController *controller,
                                  NSString *title,
                                  NSUInteger active,
                                  NSUInteger installed) {
    if (!controller) return;
    NSUInteger failed = active >= installed ? active - installed : 0;
    NSString *message = [NSString stringWithFormat:
        @"Overrides persistidos: %lu\nHooks exatos instalados/reaplicados: %lu\nPendentes/falharam: %lu",
        (unsigned long)active,
        (unsigned long)installed,
        (unsigned long)failed];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"Aplicar"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIViewController *presenter = controller;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void WAGRLocalApplyInstallButton(UIViewController *controller,
                                        SEL action,
                                        const void *associationKey) {
    if (!controller || !action) return;

    UIBarButtonItem *apply = objc_getAssociatedObject(controller, associationKey);
    NSMutableArray<UIBarButtonItem *> *items =
        [controller.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];

    if (!apply) {
        for (UIBarButtonItem *item in items) {
            if ([item.title isEqualToString:@"Aplicar"]) {
                apply = item;
                break;
            }
        }
    }

    if (!apply) {
        apply = [[UIBarButtonItem alloc] initWithTitle:@"Aplicar"
                                                style:UIBarButtonItemStyleDone
                                               target:controller
                                               action:action];
        // The first item is the trailing/right-most item.  Keep Fetch/Refresh
        // intact and put Apply at the primary action position.
        [items insertObject:apply atIndex:0];
        controller.navigationItem.rightBarButtonItems = items;
    } else {
        apply.target = controller;
        apply.action = action;
    }

    apply.accessibilityLabel = @"Aplicar overrides runtime";
    objc_setAssociatedObject(controller, associationKey, apply,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WAGRLocalApplyABOverrides(id self, __unused SEL _cmd) {
    NSArray<WAGRABPropEntry *> *entries = WAGRLocalApplyKVC(self, @"allEntries");
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSUInteger active = 0;
    NSUInteger installed = 0;

    for (WAGRABPropEntry *entry in entries ?: @[]) {
        if (!entry.className.length || !entry.selectorName.length || !entry.typeCode.length) continue;
        NSString *uid = WAGRRuntimeValueUID(entry.className, entry.selectorName, entry.classMethod);
        if (!uid.length || [seen containsObject:uid]) continue;
        [seen addObject:uid];
        if (!WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) continue;
        active++;
        if (WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                        entry.classMethod, entry.typeCode)) {
            installed++;
        }
    }

    // If the browser has not completed its first scan yet, do not turn Apply
    // into a no-op.  Reinstall the persisted runtime store globally instead.
    if (entries.count == 0) {
        NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();
        active = specs.count;
        installed = WAGRRuntimeValueReinstallPersistedHooks();
    }

    WAGRLocalApplyRefresh(self);
    WAGRLocalApplyPresent((UIViewController *)self, @"Aplicar ABProperties", active, installed);
}

static void WAGRLocalApplySurfaceOverrides(id self, __unused SEL _cmd) {
    NSArray<WAGREntry *> *entries = WAGRLocalApplyKVC(self, @"allEntries");
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSUInteger active = 0;
    NSUInteger installed = 0;

    // Deliberately use allEntries rather than filtered/visible sections.  Search
    // and scope filters must never decide which persisted overrides get applied.
    for (WAGREntry *entry in entries ?: @[]) {
        if (!entry.className.length || !entry.selectorName.length || !entry.typeCode.length) continue;
        NSString *uid = WAGRRuntimeValueUID(entry.className, entry.selectorName, entry.isClassMethod);
        if (!uid.length || [seen containsObject:uid]) continue;
        [seen addObject:uid];
        if (!WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
                                         entry.isClassMethod)) continue;
        active++;
        if (WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                        entry.isClassMethod, entry.typeCode)) {
            installed++;
        }
    }

    if (entries.count == 0) {
        NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();
        active = specs.count;
        installed = WAGRRuntimeValueReinstallPersistedHooks();
    }

    WAGRLocalApplyRefresh(self);
    WAGRLocalApplyPresent((UIViewController *)self, @"Aplicar Runtime", active, installed);
}

static void WAGRLocalABViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gWAGRABOriginalViewDidAppear) gWAGRABOriginalViewDidAppear(self, _cmd, animated);
    WAGRLocalApplyInstallButton((UIViewController *)self,
                                NSSelectorFromString(@"wagr_applyABRuntimeOverrides"),
                                kWAGRABLocalApplyButtonKey);
}

static void WAGRLocalSurfaceViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gWAGRSurfaceOriginalViewDidAppear) gWAGRSurfaceOriginalViewDidAppear(self, _cmd, animated);
    WAGRLocalApplyInstallButton((UIViewController *)self,
                                NSSelectorFromString(@"wagr_applySurfaceRuntimeOverrides"),
                                kWAGRSurfaceLocalApplyButtonKey);
}

static void WAGRLocalMainApplyAllHooks(id self, SEL _cmd) {
    // Reinstall the exact typed runtime-value hooks first.  The original main
    // Apply then performs its existing GateStore/WAAB/Aura/Dogfood/LG work.
    NSUInteger runtimeInstalled = WAGRRuntimeValueReinstallPersistedHooks();
    NSLog(@"[WATweaks][Apply] runtime value hooks reapplied=%lu persisted=%lu",
          (unsigned long)runtimeInstalled,
          (unsigned long)WAGRRuntimeValueAllOverrideSpecs().count);
    if (gWAGRMainOriginalApplyAllHooks) gWAGRMainOriginalApplyAllHooks(self, _cmd);
}

static BOOL WAGRLocalApplyHookInstanceMethod(Class cls,
                                             SEL selector,
                                             IMP replacement,
                                             IMP *originalOut) {
    if (!cls || !selector || !replacement || !originalOut) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP current = method_getImplementation(method);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) {
        *originalOut = current;
        return YES;
    }

    Method ownMethod = class_getInstanceMethod(cls, selector);
    if (!ownMethod) return NO;
    *originalOut = method_getImplementation(ownMethod);
    method_setImplementation(ownMethod, replacement);
    return YES;
}

static void WAGRLocalApplyInstall(void) {
    Class ab = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (ab) {
        SEL action = NSSelectorFromString(@"wagr_applyABRuntimeOverrides");
        if (!class_getInstanceMethod(ab, action)) {
            class_addMethod(ab, action, (IMP)WAGRLocalApplyABOverrides, "v@:");
        }
        if (!gWAGRABViewHookInstalled) {
            IMP original = NULL;
            if (WAGRLocalApplyHookInstanceMethod(ab, @selector(viewDidAppear:),
                                                 (IMP)WAGRLocalABViewDidAppear, &original)) {
                gWAGRABOriginalViewDidAppear = (void (*)(id, SEL, BOOL))original;
                gWAGRABViewHookInstalled = YES;
            }
        }
    }

    Class surface = NSClassFromString(@"WAGRSurfaceBrowserVC");
    if (surface) {
        SEL action = NSSelectorFromString(@"wagr_applySurfaceRuntimeOverrides");
        if (!class_getInstanceMethod(surface, action)) {
            class_addMethod(surface, action, (IMP)WAGRLocalApplySurfaceOverrides, "v@:");
        }
        if (!gWAGRSurfaceViewHookInstalled) {
            IMP original = NULL;
            if (WAGRLocalApplyHookInstanceMethod(surface, @selector(viewDidAppear:),
                                                 (IMP)WAGRLocalSurfaceViewDidAppear, &original)) {
                gWAGRSurfaceOriginalViewDidAppear = (void (*)(id, SEL, BOOL))original;
                gWAGRSurfaceViewHookInstalled = YES;
            }
        }
    }

    Class main = NSClassFromString(@"WAGRMainSettingsVC");
    if (main && !gWAGRMainApplyHookInstalled) {
        IMP original = NULL;
        if (WAGRLocalApplyHookInstanceMethod(main, NSSelectorFromString(@"applyAllHooks"),
                                             (IMP)WAGRLocalMainApplyAllHooks, &original)) {
            gWAGRMainOriginalApplyAllHooks = (void (*)(id, SEL))original;
            gWAGRMainApplyHookInstalled = YES;
        }
    }
}

__attribute__((constructor))
static void WAGRRuntimeLocalApplyCtor(void) {
    @autoreleasepool {
        WAGRLocalApplyInstall();
        // Retry on the main queue to make the wiring independent from source/link
        // constructor order and from the delayed final ABProps UI installer.
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRLocalApplyInstall(); });
    }
}
