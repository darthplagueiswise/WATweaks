#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

// Local Apply bridge for the runtime editors.
//
// WAGRMainSettingsVC historically reapplied GateStore/WAAB central hooks, while
// ABPropsBrowserVC and SurfaceBrowserVC persist their exact typed overrides in
// WAGRRuntimeValueStore. Keep those stores independent, but make every Apply
// entry point explicitly reinstall the runtime-value hooks as well.
//
// A browser edit is also allowed to remain PENDING when the exact hook cannot be
// installed at the instant the control changes. Previously the Compact/Inline UI
// deleted that persisted value immediately, which made an explicit Apply button
// unable to retry it later. The replacements below persist first, attempt an
// immediate install as a convenience, and leave failures in the store for Apply.

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
        // The first item is the trailing/right-most item. Keep Fetch/Refresh
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

#pragma mark - Persist first / apply explicitly

static UITableViewCell *WAGRLocalApplyCellForControl(UIView *control) {
    UIView *view = control;
    while (view && ![view isKindOfClass:UITableViewCell.class]) view = view.superview;
    return [view isKindOfClass:UITableViewCell.class] ? (UITableViewCell *)view : nil;
}

static UITableView *WAGRLocalApplyTableForCell(UITableViewCell *cell) {
    UIView *view = cell.superview;
    while (view && ![view isKindOfClass:UITableView.class]) view = view.superview;
    return [view isKindOfClass:UITableView.class] ? (UITableView *)view : nil;
}

static id WAGRLocalApplyEntryForControl(id controller, UIView *control) {
    UITableViewCell *cell = WAGRLocalApplyCellForControl(control);
    UITableView *table = WAGRLocalApplyTableForCell(cell);
    NSIndexPath *indexPath = cell && table ? [table indexPathForCell:cell] : nil;
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (!indexPath || ![controller respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, indexPath); }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRLocalApplyPulsePending(UIView *control, BOOL installed) {
    if (installed) return;
    UIColor *old = control.tintColor;
    control.tintColor = UIColor.systemOrangeColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        control.tintColor = old ?: UIColor.systemBlueColor;
    });
}

static void WAGRLocalApplyABSwitchChanged(id self, __unused SEL _cmd, UISwitch *sender) {
    WAGRABPropEntry *entry = WAGRLocalApplyEntryForControl(self, sender);
    if (!entry || !entry.typeCode.length) return;

    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, @(sender.isOn));
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.classMethod, entry.typeCode);
    // Blue means WATweaks owns a persisted override. Orange flash means it is
    // persisted but the exact hook is pending a later Apply/retry.
    sender.onTintColor = UIColor.systemBlueColor;
    WAGRLocalApplyPulsePending(sender, installed);
    WAGRLocalApplyRefresh(self);
}

static BOOL WAGRLocalApplyParseSigned(NSString *text, long long *value) {
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    long long parsed = 0;
    if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd) return NO;
    if (value) *value = parsed;
    return YES;
}

static BOOL WAGRLocalApplyParseUnsigned(NSString *text, unsigned long long *value) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed hasPrefix:@"-"]) return NO;
    char *end = NULL;
    unsigned long long parsed = strtoull(trimmed.UTF8String ?: "", &end, 10);
    if (!end || *end != '\0') return NO;
    if (value) *value = parsed;
    return YES;
}

static BOOL WAGRLocalApplyParseDouble(NSString *text, double *value) {
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    double parsed = 0.0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd) return NO;
    if (value) *value = parsed;
    return YES;
}

static void WAGRLocalApplyABFieldCommit(id self, __unused SEL _cmd, UITextField *field) {
    WAGRABPropEntry *entry = WAGRLocalApplyEntryForControl(self, field);
    if (!entry || !entry.typeCode.length) return;

    NSString *text = [field.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    id value = nil;
    BOOL valid = YES;

    if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode)) {
        long long parsed = 0;
        valid = WAGRLocalApplyParseSigned(text, &parsed);
        if (valid) value = @(parsed);
    } else if (WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode)) {
        unsigned long long parsed = 0;
        valid = WAGRLocalApplyParseUnsigned(text, &parsed);
        if (valid) value = @(parsed);
    } else if (WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) {
        double parsed = 0.0;
        valid = WAGRLocalApplyParseDouble(text, &parsed);
        if (valid) value = @(parsed);
    } else if (WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        // Inline object editing is exposed only for string-like ABProperties.
        value = text;
    } else {
        valid = NO;
    }

    if (!valid || !value) {
        field.textColor = UIColor.systemRedColor;
        return;
    }

    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, value);
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.classMethod, entry.typeCode);
    field.textColor = UIColor.systemBlueColor;
    field.tintColor = UIColor.systemBlueColor;
    WAGRLocalApplyPulsePending(field, installed);
    WAGRLocalApplyRefresh(self);
}

static void WAGRLocalApplySurfaceSwitchChanged(id self, __unused SEL _cmd, UISwitch *sender) {
    WAGREntry *entry = WAGRLocalApplyEntryForControl(self, sender);
    if (!entry || !entry.typeCode.length) return;

    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.isClassMethod, entry.typeCode, @(sender.isOn));
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.isClassMethod, entry.typeCode);
    sender.onTintColor = UIColor.systemBlueColor;
    WAGRLocalApplyPulsePending(sender, installed);
    WAGRLocalApplyRefresh(self);
}

static void WAGRLocalApplyReplaceActionIfPresent(Class cls, NSString *name, IMP replacement) {
    if (!cls || !name.length || !replacement) return;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    if (method_getImplementation(method) != replacement) {
        method_setImplementation(method, replacement);
    }
}

static void WAGRLocalApplyInstallPendingHandlers(void) {
    Class ab = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (ab) {
        // CompactUI handler (may be active briefly) and the delayed final InlineUI
        // handler both become persist-first rather than persist-then-delete.
        WAGRLocalApplyReplaceActionIfPresent(ab, @"wagr_nativeABSwitchChanged:",
                                             (IMP)WAGRLocalApplyABSwitchChanged);
        WAGRLocalApplyReplaceActionIfPresent(ab, @"wagr_inlineABSwitchChanged:",
                                             (IMP)WAGRLocalApplyABSwitchChanged);
        WAGRLocalApplyReplaceActionIfPresent(ab, @"wagr_inlineABFieldCommit:",
                                             (IMP)WAGRLocalApplyABFieldCommit);
    }

    Class surface = NSClassFromString(@"WAGRSurfaceBrowserVC");
    if (surface) {
        WAGRLocalApplyReplaceActionIfPresent(surface, @"wagr_nativeSurfaceSwitchChanged:",
                                             (IMP)WAGRLocalApplySurfaceSwitchChanged);
    }
}

#pragma mark - Apply actions

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
    // into a no-op. Reinstall the persisted runtime store globally instead.
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

    // Deliberately use allEntries rather than filtered/visible sections. Search
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
    WAGRLocalApplyInstallPendingHandlers();
}

static void WAGRLocalSurfaceViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gWAGRSurfaceOriginalViewDidAppear) gWAGRSurfaceOriginalViewDidAppear(self, _cmd, animated);
    WAGRLocalApplyInstallButton((UIViewController *)self,
                                NSSelectorFromString(@"wagr_applySurfaceRuntimeOverrides"),
                                kWAGRSurfaceLocalApplyButtonKey);
    WAGRLocalApplyInstallPendingHandlers();
}

static void WAGRLocalMainApplyAllHooks(id self, SEL _cmd) {
    // Reinstall the exact typed runtime-value hooks first. The original main
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

    WAGRLocalApplyInstallPendingHandlers();
}

__attribute__((constructor))
static void WAGRRuntimeLocalApplyCtor(void) {
    @autoreleasepool {
        WAGRLocalApplyInstall();
        // The final AB inline renderer deliberately installs on the main queue
        // and retries at 0.35 s. Run after it and retry again so our persist-first
        // handlers remain final regardless of source/link constructor order.
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRLocalApplyInstall(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRLocalApplyInstallPendingHandlers(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRLocalApplyInstallPendingHandlers(); });
    }
}
