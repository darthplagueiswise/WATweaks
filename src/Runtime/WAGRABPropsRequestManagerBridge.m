#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "WAGRLog.h"

// Narrow read-only context bridge for the current SharedModules dependency path:
//
// WAContext / WAContextMain
//   -> networkingDependencyProvider / networking
//   -> xmppConnection
//   -> xmppConnectionABPropsRequestManager
//   -> live XMPPConnectionABPropsRequestManager
//
// Important: this bridge no longer alloc/init's a request manager. The ABT
// session bridge must observe or resolve the manager already owned by WhatsApp's
// live networking session; fabricating a parallel manager can diverge from the
// authenticated XMPP/request lifecycle.

static const char *WAGRABBridgeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABBridgeReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABBridgeSkipQualifiers(raw)[0] == '@';
}

static id WAGRABBridgeCallObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABBridgeReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRABBridgeManagerABIIsExact(id manager) {
    if (!manager) return NO;
    Method method = class_getInstanceMethod([manager class],
        NSSelectorFromString(@"requestFreshABProps:withCompletion:"));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && strcmp(encoding, "v28@0:8B16@?20") == 0;
}

static id WAGRABBridgeResolveLiveManager(id context, NSString **route) {
    if (!context) return nil;

    id direct = WAGRABBridgeCallObject(context, @"xmppConnectionABPropsRequestManager");
    if (WAGRABBridgeManagerABIIsExact(direct)) {
        if (route) *route = [NSString stringWithFormat:@"context=%@ direct=%@",
            NSStringFromClass([context class]) ?: @"?",
            NSStringFromClass([direct class]) ?: @"?"];
        return direct;
    }

    id provider = WAGRABBridgeCallObject(context, @"networkingDependencyProvider");
    if (!provider) provider = WAGRABBridgeCallObject(context, @"networking");
    id connection = WAGRABBridgeCallObject(provider, @"xmppConnection");
    if (!connection) connection = WAGRABBridgeCallObject(context, @"xmppConnection");

    id manager = WAGRABBridgeCallObject(connection, @"xmppConnectionABPropsRequestManager");
    if (!manager) manager = WAGRABBridgeCallObject(provider, @"xmppConnectionABPropsRequestManager");
    if (WAGRABBridgeManagerABIIsExact(manager)) {
        if (route) *route = [NSString stringWithFormat:@"context=%@ provider=%@ connection=%@ liveManager=%@",
            NSStringFromClass([context class]) ?: @"?",
            provider ? (NSStringFromClass([provider class]) ?: @"?") : @"nil",
            connection ? (NSStringFromClass([connection class]) ?: @"?") : @"nil",
            NSStringFromClass([manager class]) ?: @"?"];
        return manager;
    }

    if (route) *route = [NSString stringWithFormat:@"context=%@ provider=%@ connection=%@ liveManager=nil",
        NSStringFromClass([context class]) ?: @"nil",
        provider ? (NSStringFromClass([provider class]) ?: @"?") : @"nil",
        connection ? (NSStringFromClass([connection class]) ?: @"?") : @"nil"];
    return nil;
}

static id WAGRABBridgeContextManagerAccessor(id self, SEL _cmd) {
    (void)_cmd;
    NSString *route = nil;
    id manager = WAGRABBridgeResolveLiveManager(self, &route);
    WAGRLogAppendF(@"[ABProps][ManagerBridge] %@", route ?: @"unresolved");
    return manager;
}

static BOOL WAGRABBridgeInstallOnClass(Class cls) {
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method existing = class_getInstanceMethod(cls, selector);
    if (existing) {
        return WAGRABBridgeReturnsObject(existing) && method_getNumberOfArguments(existing) == 2;
    }
    return class_addMethod(cls, selector, (IMP)WAGRABBridgeContextManagerAccessor, "@16@0:8");
}

static void WAGRABBridgeInstall(void) {
    BOOL installed = NO;
    for (NSString *name in @[@"WAContext", @"WAContextMain"]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (WAGRABBridgeInstallOnClass(cls)) installed = YES;
    }
    if (installed) {
        WAGRLogAppend(@"[ABProps][ManagerBridge] live-manager-only context bridge ready");
    }
}

__attribute__((constructor))
static void WAGRABPropsRequestManagerBridgeCtor(void) {
    @autoreleasepool {
        WAGRABBridgeInstall();
        for (NSNumber *delay in @[@0.25, @0.75, @1.50, @3.00]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                           (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRABBridgeInstall(); });
        }
    }
}
