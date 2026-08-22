#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

// Static analysis of the supplied SharedModules Mach-O proves the current-build
// chain and ABI:
//   WAContext/dependency owner -> networkingDependencyProvider
//   Networking                -> xmppConnection
//   XMPPConnection             -> xmppConnectionABPropsRequestManager
//   XMPPConnectionABPropsRequestManager
//       -initWithUserContext:xmppConnection:       @32@0:8@16@24
//       -requestFreshABProps:withCompletion:       v28@0:8B16@?20
//
// The native fetch resolver already asks a context for
// -xmppConnectionABPropsRequestManager.  Some current builds expose that
// capability on the networking/XMPP layer rather than WAContext itself.  This
// bridge adds only the missing context-level forwarding accessor.  It does not
// patch executable code and it never substitutes a heuristic fetch method.

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

static BOOL WAGRABBridgeArgumentIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRABBridgeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABBridgeArgumentIsBool(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    char type = WAGRABBridgeSkipQualifiers(raw)[0];
    return type == 'B' || type == 'c' || type == 'C';
}

static BOOL WAGRABBridgeReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABBridgeSkipQualifiers(raw)[0] == 'v';
}

static id WAGRABBridgeCallObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABBridgeReturnsObject(method)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WAGRABBridgeManagerABIIsExact(id manager) {
    if (!manager) return NO;
    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([manager class], selector);
    return method && method_getNumberOfArguments(method) == 4 &&
           WAGRABBridgeReturnsVoid(method) &&
           WAGRABBridgeArgumentIsBool(method, 2) &&
           WAGRABBridgeArgumentIsObject(method, 3);
}

static id WAGRABBridgeConstructManager(id context, id connection) {
    if (!context || !connection) return nil;
    Class cls = NSClassFromString(@"XMPPConnectionABPropsRequestManager") ?:
                objc_getClass("XMPPConnectionABPropsRequestManager");
    if (!cls) return nil;

    SEL initializer = NSSelectorFromString(@"initWithUserContext:xmppConnection:");
    Method method = class_getInstanceMethod(cls, initializer);
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRABBridgeReturnsObject(method) ||
        !WAGRABBridgeArgumentIsObject(method, 2) ||
        !WAGRABBridgeArgumentIsObject(method, 3)) return nil;

    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    if (!allocated) return nil;
    id manager = nil;
    @try {
        manager = ((id (*)(id, SEL, id, id))objc_msgSend)(allocated,
                                                           initializer,
                                                           context,
                                                           connection);
    } @catch (__unused NSException *exception) {
        manager = nil;
    }
    return WAGRABBridgeManagerABIIsExact(manager) ? manager : nil;
}

static id WAGRABBridgeResolveFromContext(id context, NSString **route) {
    if (!context) return nil;

    // 1. If a native context-level accessor exists after all, use it untouched.
    id direct = WAGRABBridgeCallObject(context, @"xmppConnectionABPropsRequestManager");
    if (WAGRABBridgeManagerABIIsExact(direct)) {
        if (route) *route = @"context.xmppConnectionABPropsRequestManager";
        return direct;
    }

    // 2. Current-build dependency path proven in SharedModules metadata.
    id provider = WAGRABBridgeCallObject(context, @"networkingDependencyProvider");
    if (!provider) provider = WAGRABBridgeCallObject(context, @"networking");
    if (!provider) provider = context;

    id connection = WAGRABBridgeCallObject(provider, @"xmppConnection");
    if (!connection && provider != context) {
        connection = WAGRABBridgeCallObject(context, @"xmppConnection");
    }

    id manager = WAGRABBridgeCallObject(connection, @"xmppConnectionABPropsRequestManager");
    if (WAGRABBridgeManagerABIIsExact(manager)) {
        if (route) {
            *route = [NSString stringWithFormat:@"%@ -> %@ -> %@",
                NSStringFromClass([provider class]) ?: @"provider",
                NSStringFromClass([connection class]) ?: @"XMPPConnection",
                NSStringFromClass([manager class]) ?: @"XMPPConnectionABPropsRequestManager"];
        }
        return manager;
    }

    // 3. The class initializer/ABI is also present in the same Mach-O.  Only use
    // it when the exact live XMPPConnection was resolved and the result validates
    // the exact fresh-fetch selector; this is deterministic, not a lookalike scan.
    manager = WAGRABBridgeConstructManager(context, connection);
    if (manager) {
        if (route) {
            *route = [NSString stringWithFormat:@"constructed %@ with live %@",
                NSStringFromClass([manager class]) ?: @"XMPPConnectionABPropsRequestManager",
                NSStringFromClass([connection class]) ?: @"XMPPConnection"];
        }
        return manager;
    }

    if (route) {
        *route = [NSString stringWithFormat:@"context=%@ provider=%@ connection=%@ manager=nil",
            NSStringFromClass([context class]) ?: @"nil",
            provider ? NSStringFromClass([provider class]) : @"nil",
            connection ? NSStringFromClass([connection class]) : @"nil"];
    }
    return nil;
}

static id WAGRABBridgeContextManagerAccessor(id self, SEL _cmd) {
    (void)_cmd;
    NSString *route = nil;
    id manager = WAGRABBridgeResolveFromContext(self, &route);
    WAGRLogAppendF(@"[ABProps][ManagerBridge] %@", route ?: @"unresolved");
    return manager;
}

static BOOL WAGRABBridgeInstallOnClass(Class cls) {
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method existing = class_getInstanceMethod(cls, selector);
    if (existing) {
        // Never override a native implementation.
        return WAGRABBridgeReturnsObject(existing) &&
               method_getNumberOfArguments(existing) == 2;
    }
    return class_addMethod(cls, selector,
                           (IMP)WAGRABBridgeContextManagerAccessor,
                           "@16@0:8");
}

static void WAGRABBridgeInstall(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });

    @synchronized (lock) {
        BOOL installed = NO;
        for (NSString *name in @[@"WAContext", @"WAContextMain"]) {
            Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
            if (WAGRABBridgeInstallOnClass(cls)) installed = YES;
        }
        if (installed) {
            WAGRLogAppend(@"[ABProps][ManagerBridge] current-build networking bridge ready");
        }
    }
}

__attribute__((constructor))
static void WAGRABPropsRequestManagerBridgeCtor(void) {
    @autoreleasepool {
        WAGRABBridgeInstall();
        // Classes may be registered after tweak constructors in some sideload
        // layouts.  Retrying class_addMethod is safe and does not touch __TEXT.
        for (NSNumber *delay in @[@0.25, @0.75, @1.5, @3.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ WAGRABBridgeInstall(); });
        }
    }
}
