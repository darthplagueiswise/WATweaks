#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#include <string.h>

#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

static const char *WAGRMCPrimeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCPrimeReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCPrimeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCPrimeReturnsBoolLike(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    char t = WAGRMCPrimeSkipQualifiers(raw)[0];
    return t == 'B' || t == 'c' || t == 'C';
}

static id WAGRMCPrimeClassObject(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMCPrimeReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRMCPrimeBool(id object, NSString *selectorName, BOOL *available) {
    if (available) *available = NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = object ? class_getInstanceMethod([object class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMCPrimeReturnsBoolLike(method)) return NO;
    if (available) *available = YES;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return NO; }
}

static BOOL WAGRMCPrimeUsable(id manager) {
    if (!manager) return NO;
    NSString *name = NSStringFromClass([manager class]) ?: @"";
    if (![name containsString:@"FBMobileConfigContextManager"]) return NO;
    BOOL managerAvailable = NO, configAvailable = NO;
    BOOL hasManager = WAGRMCPrimeBool(manager, @"hasValidManager", &managerAvailable);
    BOOL hasConfig = WAGRMCPrimeBool(manager, @"hasValidConfig", &configAvailable);
    if (managerAvailable && !hasManager) return NO;
    if (configAvailable && !hasConfig) return NO;
    Method stable = class_getInstanceMethod([manager class], NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    return stable && method_getNumberOfArguments(stable) == 3;
}

static void WAGRMobileConfigPrimeDeterministicManager(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        WAGRMobileConfigEnsureCaptureHooksInstalled();
        if (WAGRMobileConfigContextManager(nil)) return;

        Class cls = NSClassFromString(@"FBMobileConfigContextManager") ?: objc_getClass("FBMobileConfigContextManager");
        for (NSString *selectorName in @[@"sessionlessContextManager", @"defaultValueContextManager"]) {
            id candidate = WAGRMCPrimeClassObject(cls, selectorName);
            if (!WAGRMCPrimeUsable(candidate)) continue;

            // getOverridesTablePath is already observed by WAGRMobileConfigBridge.
            // Calling it is read-only and lets the bridge remember this deterministic
            // manager without patching any WATweaks executable page.
            SEL pathSelector = NSSelectorFromString(@"getOverridesTablePath");
            Method pathMethod = class_getInstanceMethod([candidate class], pathSelector);
            if (pathMethod && method_getNumberOfArguments(pathMethod) == 2 && WAGRMCPrimeReturnsObject(pathMethod)) {
                @try { (void)((id (*)(id, SEL))objc_msgSend)(candidate, pathSelector); }
                @catch (__unused NSException *exception) {}
            }

            if (WAGRMobileConfigContextManager(nil)) {
                WAGRLogAppendF(@"[MobileConfig][SideloadSafe] primed via +%@", selectorName);
                return;
            }
        }
    }
}

static void WAGRMCPrimeImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    dispatch_async(dispatch_get_main_queue(), ^{ WAGRMobileConfigPrimeDeterministicManager(); });
}

__attribute__((constructor))
static void WAGRMobileConfigSideloadBootstrapCtor(void) {
    @autoreleasepool {
        WAGRMobileConfigPrimeDeterministicManager();
        _dyld_register_func_for_add_image(WAGRMCPrimeImageAdded);
    }
}
