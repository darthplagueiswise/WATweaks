#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#include <string.h>

#import "WAGRLog.h"

// Current WhatsApp/SharedModules dependency chain, validated from the supplied
// binary's Objective-C/Swift metadata:
//
//   XMPPConnection
//      -> networkingDependencyProvider
//      -> WANetworkingDependencyProvidingPlugin.NetworkingDependencyProvider
//      -> xmppConnectionABPropsRequestManager
//      -> XMPPConnectionABPropsRequestManager
//
// WAGRABPropsNativeStore deliberately resolves only exact ABI-validated getters.
// The store already walks `xmppConnectionABPropsRequestManager` on objects it can
// reach, but XMPPConnection does not expose that leaf directly.  This bridge adds
// a read-only forwarding getter to XMPPConnection's Objective-C method table.
// No executable page is modified; class_addMethod updates runtime metadata only.

static const char *WAGRABNetSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABNetObjectGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABNetSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABNetFreshFetchABI(id manager) {
    if (!manager) return NO;
    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 4) return NO;

    char ret[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    if (WAGRABNetSkipQualifiers(ret)[0] != 'v') return NO;

    char delta[32] = {0};
    method_getArgumentType(method, 2, delta, sizeof(delta));
    char deltaType = WAGRABNetSkipQualifiers(delta)[0];
    if (!(deltaType == 'B' || deltaType == 'c' || deltaType == 'C')) return NO;

    char completion[32] = {0};
    method_getArgumentType(method, 3, completion, sizeof(completion));
    return WAGRABNetSkipQualifiers(completion)[0] == '@';
}

static id WAGRABNetCallGetter(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!WAGRABNetObjectGetter(method)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][NetworkingBridge] %@.%@ threw %@",
                       NSStringFromClass([target class]) ?: @"?",
                       selectorName,
                       exception.reason ?: @"exception");
        return nil;
    }
}

static id WAGRABNetForwardRequestManager(id connection, __unused SEL selector) {
    id provider = WAGRABNetCallGetter(connection, @"networkingDependencyProvider");
    if (!provider) {
        WAGRLogAppendF(@"[ABProps][NetworkingBridge] %@ has no live networkingDependencyProvider",
                       NSStringFromClass([connection class]) ?: @"XMPPConnection");
        return nil;
    }

    id manager = WAGRABNetCallGetter(provider, @"xmppConnectionABPropsRequestManager");
    if (!manager) {
        WAGRLogAppendF(@"[ABProps][NetworkingBridge] provider %@ returned no ABProps request manager",
                       NSStringFromClass([provider class]) ?: @"?");
        return nil;
    }

    if (!WAGRABNetFreshFetchABI(manager)) {
        WAGRLogAppendF(@"[ABProps][NetworkingBridge] rejected %@: requestFreshABProps ABI mismatch",
                       NSStringFromClass([manager class]) ?: @"?");
        return nil;
    }

    WAGRLogAppendF(@"[ABProps][NetworkingBridge] resolved %@ -> %@ -> %@",
                   NSStringFromClass([connection class]) ?: @"XMPPConnection",
                   NSStringFromClass([provider class]) ?: @"NetworkingDependencyProvider",
                   NSStringFromClass([manager class]) ?: @"XMPPConnectionABPropsRequestManager");
    return manager;
}

static BOOL WAGRABNetInstallBridge(void) {
    Class connectionClass = NSClassFromString(@"XMPPConnection") ?: objc_getClass("XMPPConnection");
    if (!connectionClass) return NO;

    SEL providerSelector = NSSelectorFromString(@"networkingDependencyProvider");
    Method providerMethod = class_getInstanceMethod(connectionClass, providerSelector);
    if (!WAGRABNetObjectGetter(providerMethod)) {
        WAGRLogAppend(@"[ABProps][NetworkingBridge] XMPPConnection.networkingDependencyProvider ABI unavailable");
        return NO;
    }

    SEL leafSelector = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method existing = class_getInstanceMethod(connectionClass, leafSelector);
    if (existing) {
        // Future/current builds may expose the leaf directly. Never replace it.
        WAGRLogAppend(@"[ABProps][NetworkingBridge] XMPPConnection already exposes xmppConnectionABPropsRequestManager");
        return YES;
    }

    BOOL added = class_addMethod(connectionClass,
                                 leafSelector,
                                 (IMP)WAGRABNetForwardRequestManager,
                                 "@@:");
    if (added) {
        WAGRLogAppend(@"[ABProps][NetworkingBridge] installed sideload-safe XMPPConnection forwarding getter");
        return YES;
    }

    // A concurrent installer may have won the race.
    return class_getInstanceMethod(connectionClass, leafSelector) != NULL;
}

static void WAGRABNetImageAdded(__unused const struct mach_header *header,
                                __unused intptr_t slide) {
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)WAGRABNetInstallBridge();
    });
}

__attribute__((constructor))
static void WAGRABPropsNetworkingBridgeCtor(void) {
    @autoreleasepool {
        (void)WAGRABNetInstallBridge();
        _dyld_register_func_for_add_image(WAGRABNetImageAdded);
    }
}
