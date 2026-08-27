#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

// The current SharedModules build exposes the exact native chain:
// XMPPConnectionABPropsRequestManager
//   -initWithUserContext:xmppConnection:
//   -requestFreshABProps:withCompletion:
//
// The previous WATweaks fetch resolver started from WAGRCurrentUserContext().
// If the native Developer Menu had never handed us that context, the root was
// nil even though the real request manager was alive. Capture the manager at its
// own native initializer and remember the account-scoped userContext passed by
// WhatsApp. No networking selector is guessed and no arbitrary sync method is
// invoked.

static __weak id gWAGRABCapturedManager = nil;
static __weak id gWAGRABCapturedContext = nil;
static id (*gWAGRABOriginalManagerInit)(id, SEL, id, id) = NULL;
static void (*gWAGRABOriginalBrowserScan)(id, SEL) = NULL;
static void (*gWAGRABOriginalBrowserFetch)(id, SEL) = NULL;
static BOOL gWAGRABManagerCaptureInstalled = NO;
static BOOL gWAGRABBrowserContextRepairInstalled = NO;

static const char *WAGRABCaptureSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABCaptureReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABCaptureSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABCaptureArgIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRABCaptureSkipQualifiers(raw)[0] == '@';
}

static id WAGRABCaptureCallObjectNoArg(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABCaptureReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABCaptureCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABCaptureReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRABCaptureCanFreshFetch(id object) {
    if (!object) return NO;
    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    char returnRaw[32] = {0};
    method_getReturnType(method, returnRaw, sizeof(returnRaw));
    if (WAGRABCaptureSkipQualifiers(returnRaw)[0] != 'v') return NO;
    char boolRaw[32] = {0};
    method_getArgumentType(method, 2, boolRaw, sizeof(boolRaw));
    char boolType = WAGRABCaptureSkipQualifiers(boolRaw)[0];
    if (boolType != 'B' && boolType != 'c' && boolType != 'C') return NO;
    return WAGRABCaptureArgIsObject(method, 3);
}

static BOOL WAGRABCaptureLooksLikeContext(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]) ?: @"";
    if ([name containsString:@"UserContext"] || [name isEqualToString:@"WAContext"] ||
        [name containsString:@"WAContext"] || [name containsString:@"ContextMain"]) return YES;
    return [object respondsToSelector:NSSelectorFromString(@"networkingDependencyProvider")] ||
           [object respondsToSelector:NSSelectorFromString(@"abProperties")];
}

static void WAGRABCaptureRemember(id manager, id context, NSString *source) {
    if (manager && WAGRABCaptureCanFreshFetch(manager)) gWAGRABCapturedManager = manager;
    if (context && WAGRABCaptureLooksLikeContext(context)) {
        gWAGRABCapturedContext = context;
        WAGRRememberUserContext(context, source ?: @"ABProps manager capture");
    }
    WAGRLogAppendF(@"[ABProps][ManagerCapture] manager=%@ context=%@ source=%@",
                   gWAGRABCapturedManager ? NSStringFromClass([gWAGRABCapturedManager class]) : @"nil",
                   gWAGRABCapturedContext ? NSStringFromClass([gWAGRABCapturedContext class]) : @"nil",
                   source ?: @"unknown");
}

static id WAGRABCaptureContextFromManager(id manager) {
    if (!manager) return nil;
    for (NSString *selectorName in @[@"userContext", @"context", @"waContext"]) {
        id context = WAGRABCaptureCallObjectNoArg(manager, selectorName);
        if (WAGRABCaptureLooksLikeContext(context)) return context;
    }

    // Targeted fallback only: inspect the known initializer's backing context
    // ivar by name, never traverse an arbitrary ivar graph.
    const char *ivarNames[] = {"_userContext", "userContext", "_context"};
    const NSUInteger ivarNameCount = sizeof(ivarNames) / sizeof(ivarNames[0]);
    for (NSUInteger index = 0; index < ivarNameCount; index++) {
        const char *name = ivarNames[index];
        Ivar ivar = class_getInstanceVariable([manager class], name);
        if (!ivar) continue;
        const char *encoding = ivar_getTypeEncoding(ivar);
        if (WAGRABCaptureSkipQualifiers(encoding)[0] != '@') continue;
        id value = nil;
        @try { value = object_getIvar(manager, ivar); }
        @catch (__unused NSException *exception) { value = nil; }
        if (WAGRABCaptureLooksLikeContext(value)) return value;
    }
    return nil;
}

static id WAGRABCapturedManagerInit(id self, SEL _cmd, id userContext, id xmppConnection) {
    id result = gWAGRABOriginalManagerInit
        ? gWAGRABOriginalManagerInit(self, _cmd, userContext, xmppConnection) : self;
    id manager = result ?: self;
    WAGRABCaptureRemember(manager, userContext,
                          @"XMPPConnectionABPropsRequestManager initWithUserContext:xmppConnection:");
    return result;
}

static void WAGRABInstallManagerCapture(void) {
    if (gWAGRABManagerCaptureInstalled) return;
    Class cls = NSClassFromString(@"XMPPConnectionABPropsRequestManager") ?:
                objc_getClass("XMPPConnectionABPropsRequestManager");
    SEL selector = NSSelectorFromString(@"initWithUserContext:xmppConnection:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRABCaptureReturnsObject(method) ||
        !WAGRABCaptureArgIsObject(method, 2) ||
        !WAGRABCaptureArgIsObject(method, 3)) return;

    IMP current = method_getImplementation(method);
    if (!current || current == (IMP)WAGRABCapturedManagerInit) {
        gWAGRABManagerCaptureInstalled = (current == (IMP)WAGRABCapturedManagerInit);
        return;
    }
    gWAGRABOriginalManagerInit = (id (*)(id, SEL, id, id))current;
    method_setImplementation(method, (IMP)WAGRABCapturedManagerInit);
    gWAGRABManagerCaptureInstalled = YES;
    WAGRLogAppend(@"[ABProps][ManagerCapture] exact native manager initializer capture installed");
}

static id WAGRABFindManagerFromRoot(id root,
                                    NSMutableSet<NSValue *> *visited,
                                    NSUInteger depth) {
    if (!root || depth > 7) return nil;
    if (WAGRABCaptureCanFreshFetch(root)) {
        id context = WAGRABCaptureContextFromManager(root);
        WAGRABCaptureRemember(root, context, @"bounded native dependency graph");
        return root;
    }

    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if (WAGRABCaptureLooksLikeContext(root) && !gWAGRABCapturedContext) {
        WAGRABCaptureRemember(nil, root, @"bounded native dependency graph context");
    }

    // These are dependency/accessor names present in the current WhatsApp /
    // SharedModules binary. We only traverse zero-argument object getters and
    // still require the exact requestFreshABProps ABI at the destination.
    for (NSString *selectorName in @[
        @"networkingDependencyProvider", @"networking", @"xmppConnection",
        @"xmppConnectionABPropsRequestManager", @"connection",
        @"userContext", @"context", @"waContext", @"underlyingWAContext",
        @"mainContext", @"currentContext"
    ]) {
        id child = WAGRABCaptureCallObjectNoArg(root, selectorName);
        if (!child || child == root) continue;
        id manager = WAGRABFindManagerFromRoot(child, visited, depth + 1);
        if (manager) return manager;
    }
    return nil;
}

static id WAGRABDiscoverManagerOnDemand(void) {
    id manager = gWAGRABCapturedManager;
    if (manager && WAGRABCaptureCanFreshFetch(manager)) return manager;

    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIApplication *application = UIApplication.sharedApplication;
    manager = WAGRABFindManagerFromRoot((id)application.delegate, visited, 0);
    if (manager) return manager;

    for (UIWindow *window in application.windows) {
        manager = WAGRABFindManagerFromRoot(window.rootViewController, visited, 0);
        if (manager) return manager;
    }

    for (NSString *className in @[@"WAContext", @"WAContextMain"]) {
        Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
        if (!cls) continue;
        for (NSString *selectorName in @[
            @"shared", @"sharedInstance", @"current", @"currentContext",
            @"mainContext", @"defaultContext", @"context", @"waContext"
        ]) {
            id root = WAGRABCaptureCallClassObjectNoArg(cls, selectorName);
            if (!root) continue;
            manager = WAGRABFindManagerFromRoot(root, visited, 0);
            if (manager) return manager;
        }
    }
    return nil;
}

static id WAGRABBestCapturedContext(void) {
    id context = gWAGRABCapturedContext ?: WAGRCurrentUserContext();
    if (context) return context;
    id manager = WAGRABDiscoverManagerOnDemand();
    context = WAGRABCaptureContextFromManager(manager);
    if (context) WAGRABCaptureRemember(manager, context, @"manager context recovery");
    return context;
}

static id WAGRABBrowserKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRABBrowserSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length || !value) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void WAGRABPrimeBrowserContext(id browser) {
    if (WAGRABBrowserKVC(browser, @"userContext")) return;
    id context = WAGRABBestCapturedContext();
    if (context) {
        WAGRABBrowserSetKVC(browser, @"userContext", context);
        WAGRLogAppendF(@"[ABProps][ManagerCapture] browser userContext repaired with %@",
                       NSStringFromClass([context class]));
    }
}

static void WAGRABBrowserScanWithContext(id self, SEL _cmd) {
    WAGRABPrimeBrowserContext(self);
    if (gWAGRABOriginalBrowserScan) gWAGRABOriginalBrowserScan(self, _cmd);
}

static void WAGRABBrowserFetchWithContext(id self, SEL _cmd) {
    WAGRABPrimeBrowserContext(self);

    // If the manager exists but its context cannot be recovered, do not silently
    // fall back to a guessed networking method. The existing fetch UI will emit
    // its precise diagnostic. Normally the initializer capture above provides
    // both objects together.
    (void)WAGRABDiscoverManagerOnDemand();
    if (gWAGRABOriginalBrowserFetch) gWAGRABOriginalBrowserFetch(self, _cmd);
}

static void WAGRABInstallBrowserContextRepair(void) {
    if (gWAGRABBrowserContextRepairInstalled) return;
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (!cls) return;

    Method scanMethod = class_getInstanceMethod(cls, NSSelectorFromString(@"scanNow"));
    IMP scanCurrent = scanMethod ? method_getImplementation(scanMethod) : NULL;
    if (scanMethod && scanCurrent && scanCurrent != (IMP)WAGRABBrowserScanWithContext) {
        gWAGRABOriginalBrowserScan = (void (*)(id, SEL))scanCurrent;
        method_setImplementation(scanMethod, (IMP)WAGRABBrowserScanWithContext);
    }

    Method fetchMethod = class_getInstanceMethod(cls, NSSelectorFromString(@"fetchNow"));
    IMP fetchCurrent = fetchMethod ? method_getImplementation(fetchMethod) : NULL;
    if (fetchMethod && fetchCurrent && fetchCurrent != (IMP)WAGRABBrowserFetchWithContext) {
        gWAGRABOriginalBrowserFetch = (void (*)(id, SEL))fetchCurrent;
        method_setImplementation(fetchMethod, (IMP)WAGRABBrowserFetchWithContext);
    }

    gWAGRABBrowserContextRepairInstalled =
        gWAGRABOriginalBrowserScan != NULL && gWAGRABOriginalBrowserFetch != NULL;
    if (gWAGRABBrowserContextRepairInstalled) {
        WAGRLogAppend(@"[ABProps][ManagerCapture] browser scan/fetch now primes the real native userContext");
    }
}

__attribute__((constructor))
static void WAGRABPropsRequestManagerCaptureCtor(void) {
    @autoreleasepool {
        WAGRABInstallManagerCapture();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WAGRABInstallManagerCapture();
            WAGRABInstallBrowserContextRepair();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.50 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WAGRABInstallManagerCapture();
            WAGRABInstallBrowserContextRepair();
        });
    }
}
