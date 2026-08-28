#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#import "WAGRABPropsNativeOverrideEngine.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

static BOOL gWAGRABDisabledSurfaceInstalled = NO;

static uintptr_t WAGRABCompatIMPAddress(IMP imp) {
#if __has_include(<ptrauth.h>)
    return (uintptr_t)ptrauth_strip((void *)imp, ptrauth_key_function_pointer);
#else
    return (uintptr_t)imp;
#endif
}

static BOOL WAGRABCompatIsRET(uint32_t instruction) {
    return instruction == 0xD65F03C0u;
}

static BOOL WAGRABCompatIsZeroMove(uint32_t instruction) {
    return instruction == 0xD2800000u || instruction == 0x52800000u;
}

static BOOL WAGRABCompatIsZeroReturnAddress(uintptr_t address, NSUInteger depth) {
    if (!address || depth > 2) return NO;
    const uint32_t *code = (const uint32_t *)address;
    uint32_t first = code[0], second = code[1];
    if (WAGRABCompatIsZeroMove(first) && WAGRABCompatIsRET(second)) return YES;
    if ((first & 0x7C000000u) == 0x14000000u) {
        int32_t imm26 = (int32_t)(first & 0x03FFFFFFu);
        if (imm26 & 0x02000000) imm26 |= (int32_t)0xFC000000u;
        uintptr_t target = address + ((intptr_t)imm26 << 2);
        return WAGRABCompatIsZeroReturnAddress(target, depth + 1);
    }
    return NO;
}

static BOOL WAGRABCompatIsDirectRET(IMP imp) {
    uintptr_t address = WAGRABCompatIMPAddress(imp);
    return address && WAGRABCompatIsRET(*(const uint32_t *)address);
}

static const char *WAGRABCompatSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABCompatReturnsObject(Method method) {
    if (!method) return NO;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABCompatSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABCompatReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return strchr("cCsSiIlLqQB", WAGRABCompatSkipQualifiers(raw)[0]) != NULL;
}

static long long WAGRABCompatSync(id self, SEL _cmd, id userContext) {
    (void)self; (void)_cmd;
    id context = userContext ?: WAGRCurrentUserContext();
    NSString *diagnostic = nil;
    NSInteger applied = WAGRABPropsNativeSyncTrackedOverrides(context, &diagnostic);
    WAGRLogAppendF(@"[ABProps][ReleaseCompat] sync stub -> native StartupConfigs/MC: %@",
                   diagnostic ?: @"no diagnostic");
    return (long long)applied;
}

static id WAGRABCompatOverriddenStableIDs(id self, SEL _cmd, id userContext) {
    (void)self; (void)_cmd; (void)userContext;
    return WAGRABPropsNativeTrackedStableIDs();
}

static void WAGRABCompatResetAll(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    NSString *diagnostic = nil;
    NSInteger cleared = WAGRABPropsNativeClearTrackedOverrides(WAGRCurrentUserContext(), &diagnostic);
    WAGRLogAppendF(@"[ABProps][ReleaseCompat] reset stub -> clear WATweaks-owned native overrides: cleared=%ld %@",
                   (long)cleared, diagnostic ?: @"");
}

static BOOL WAGRABCompatOriginalStableIDsAreEmpty(Class cls, Method method) {
    if (!cls || !method || method_getNumberOfArguments(method) != 3 || !WAGRABCompatReturnsObject(method)) return NO;
    SEL selector = method_getName(method);
    @try {
        id value = ((id (*)(id, SEL, id))objc_msgSend)((id)cls, selector, nil);
        return [value isKindOfClass:NSArray.class] && [(NSArray *)value count] == 0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void WAGRABInstallDisabledSurfaceCompatibility(void) {
    if (gWAGRABDisabledSurfaceInstalled) return;
    BOOL syncInstalled = NO, idsInstalled = NO, resetInstalled = NO;

    Class syncClass = NSClassFromString(@"WAMobileConfigABPropsOverridesSync") ?:
                      objc_getClass("WAMobileConfigABPropsOverridesSync");
    if (syncClass) {
        SEL syncSelector = NSSelectorFromString(@"syncABPropsOverridesToMCWithUserContext:");
        Method syncMethod = class_getClassMethod(syncClass, syncSelector);
        IMP syncIMP = syncMethod ? method_getImplementation(syncMethod) : NULL;
        BOOL syncIsReleaseStub = syncMethod && method_getNumberOfArguments(syncMethod) == 3 &&
                                 WAGRABCompatReturnsInteger(syncMethod) &&
                                 WAGRABCompatIsZeroReturnAddress(WAGRABCompatIMPAddress(syncIMP), 0);
        if (syncIsReleaseStub) {
            method_setImplementation(syncMethod, (IMP)WAGRABCompatSync);
            syncInstalled = method_getImplementation(syncMethod) == (IMP)WAGRABCompatSync;
        }

        SEL idsSelector = NSSelectorFromString(@"overriddenStableIdsWithUserContext:");
        Method idsMethod = class_getClassMethod(syncClass, idsSelector);
        if (syncIsReleaseStub && WAGRABCompatOriginalStableIDsAreEmpty(syncClass, idsMethod)) {
            method_setImplementation(idsMethod, (IMP)WAGRABCompatOverriddenStableIDs);
            idsInstalled = method_getImplementation(idsMethod) == (IMP)WAGRABCompatOverriddenStableIDs;
        }
    }

    Class debugClass = NSClassFromString(@"WADebugViewController") ?: objc_getClass("WADebugViewController");
    SEL resetSelector = NSSelectorFromString(@"resetAllOverriddenABProps");
    Method resetMethod = debugClass ? class_getInstanceMethod(debugClass, resetSelector) : NULL;
    IMP resetIMP = resetMethod ? method_getImplementation(resetMethod) : NULL;
    if (resetMethod && method_getNumberOfArguments(resetMethod) == 2 && WAGRABCompatIsDirectRET(resetIMP)) {
        method_setImplementation(resetMethod, (IMP)WAGRABCompatResetAll);
        resetInstalled = method_getImplementation(resetMethod) == (IMP)WAGRABCompatResetAll;
    }

    gWAGRABDisabledSurfaceInstalled = syncInstalled || idsInstalled || resetInstalled;
    if (gWAGRABDisabledSurfaceInstalled) {
        WAGRLogAppendF(@"[ABProps][ReleaseCompat] installed sync=%@ ids=%@ reset=%@",
                       syncInstalled ? @"YES" : @"NO", idsInstalled ? @"YES" : @"NO",
                       resetInstalled ? @"YES" : @"NO");
    }
}

__attribute__((constructor))
static void WAGRABPropsDisabledSurfaceCompatibilityCtor(void) {
    @autoreleasepool {
        // No class enumeration or dependency-graph scan at launch: only these
        // three explicitly named release surfaces are checked after normal load.
        for (NSNumber *delay in @[@0.5, @1.5, @3.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRABInstallDisabledSurfaceCompatibility();
            });
        }
    }
}
