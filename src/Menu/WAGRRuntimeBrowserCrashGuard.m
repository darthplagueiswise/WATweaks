#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "../Runtime/WAGRSurface.h"

/*
 * Crash guard for the generic runtime browser.
 *
 * The previous fast receiver resolver recursively walked arbitrary object ivars
 * with object_getIvar() while table cells were being rendered.  That is not a
 * safe way to discover live receivers: object-typed ivars may be weak,
 * transient, implementation-private, or point at objects whose lifetime is not
 * owned by the browser.  Retaining / messaging those guesses can crash simply
 * by opening an image.
 *
 * Keep receiver discovery conservative.  We only use objects already owned by
 * the scanner, validated singleton factories, and UIKit objects already owned
 * by the visible hierarchy.  We never alloc/init a guessed object and never
 * traverse arbitrary ivar graphs.
 */

static id WAGRSafeKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static const char *WAGRSafeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRSafeExactReceiver(id object, Class cls, SEL selector) {
    return object && cls && [object isKindOfClass:cls] && [object respondsToSelector:selector];
}

static id WAGRSafeSingletonReceiver(Class cls, SEL selector) {
    if (!cls || !selector) return nil;
    static NSArray<NSString *> *factories;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        factories = @[
            @"shared", @"sharedInstance", @"current", @"defaultInstance",
            @"defaultManager", @"manager", @"provider", @"properties",
            @"instance", @"getInstance"
        ];
    });

    for (NSString *name in factories) {
        SEL factory = NSSelectorFromString(name);
        Method method = class_getClassMethod(cls, factory);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char raw[64] = {0};
        method_getReturnType(method, raw, sizeof(raw));
        if (WAGRSafeSkipQualifiers(raw)[0] != '@') continue;
        @try {
            id candidate = ((id (*)(id, SEL))objc_msgSend)((id)cls, factory);
            if (WAGRSafeExactReceiver(candidate, cls, selector)) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static id WAGRSafeFindView(UIView *view, Class cls, SEL selector) {
    if (!view) return nil;
    if (WAGRSafeExactReceiver(view, cls, selector)) return view;
    for (UIView *child in view.subviews) {
        id candidate = WAGRSafeFindView(child, cls, selector);
        if (candidate) return candidate;
    }
    return nil;
}

static id WAGRSafeFindController(UIViewController *controller,
                                 Class cls,
                                 SEL selector,
                                 NSUInteger depth) {
    if (!controller || depth > 20) return nil;
    if (WAGRSafeExactReceiver(controller, cls, selector)) return controller;

    UIView *loadedView = controller.isViewLoaded ? controller.view : nil;
    id inView = WAGRSafeFindView(loadedView, cls, selector);
    if (inView) return inView;

    for (UIViewController *child in controller.childViewControllers) {
        id candidate = WAGRSafeFindController(child, cls, selector, depth + 1);
        if (candidate) return candidate;
    }
    if (controller.presentedViewController) {
        id candidate = WAGRSafeFindController(controller.presentedViewController,
                                               cls, selector, depth + 1);
        if (candidate) return candidate;
    }
    return nil;
}

static id WAGRSafeReceiverForEntry(id self, __unused SEL _cmd, WAGREntry *entry) {
    if (!entry || entry.isClassMethod || !entry.className.length || !entry.selectorName.length) {
        return nil;
    }

    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    if (!cls || !selector) return nil;

    // 1) Objects explicitly captured by the runtime scanner are already live and
    // owned by the browser.  Require the exact class family, never just a selector
    // collision on an unrelated object.
    NSArray *runtimeObjects = WAGRSafeKVC(self, @"runtimeObjects");
    if ([runtimeObjects isKindOfClass:NSArray.class]) {
        for (id object in runtimeObjects) {
            if (WAGRSafeExactReceiver(object, cls, selector)) return object;
        }
    }

    // 2) Known zero-argument singleton factories, ABI checked before invocation.
    id singleton = WAGRSafeSingletonReceiver(cls, selector);
    if (singleton) return singleton;

    // 3) UIKit-owned graph only.  This is useful for view/controller runtime
    // surfaces and has deterministic ownership; it intentionally does not walk
    // arbitrary ivars of application model objects.
    UIApplication *application = UIApplication.sharedApplication;
    id delegate = application.delegate;
    if (WAGRSafeExactReceiver(delegate, cls, selector)) return delegate;
    for (UIWindow *window in application.windows) {
        if (WAGRSafeExactReceiver(window, cls, selector)) return window;
        id candidate = WAGRSafeFindController(window.rootViewController, cls, selector, 0);
        if (candidate) return candidate;
    }

    return nil;
}

static void WAGRInstallRuntimeCrashGuard(void) {
    Class cls = NSClassFromString(@"WAGRSurfaceBrowserVC");
    SEL selector = NSSelectorFromString(@"receiverForEntry:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    if (method_getImplementation(method) == (IMP)WAGRSafeReceiverForEntry) return;
    method_setImplementation(method, (IMP)WAGRSafeReceiverForEntry);
}

__attribute__((constructor))
static void WAGRRuntimeBrowserCrashGuardCtor(void) {
    @autoreleasepool {
        // FastTypedUI intentionally installs late (0.85 s).  Install after it so
        // unsafe ivar-graph receiver discovery cannot become the final IMP.
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WAGRInstallRuntimeCrashGuard();
            });
        });
    }
}
