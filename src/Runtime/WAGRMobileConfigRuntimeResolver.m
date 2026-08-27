#import "WAGRMobileConfigRuntimeResolver.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

static const char *WAGRMCRuntimeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCRuntimeReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCRuntimeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCRuntimeReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRMCRuntimeSkipQualifiers(raw)[0]) {
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
            return YES;
        default:
            return NO;
    }
}

static BOOL WAGRMCRuntimeArgumentFitsWord(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[128] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRMCRuntimeSkipQualifiers(raw);
    if (!*type) return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static id WAGRMCRuntimeCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMCRuntimeReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRMCRuntimeCanResolveStableId(id manager) {
    if (!manager) return NO;
    Class expected = NSClassFromString(@"FBMobileConfigUserSessionContextManager") ?:
                     objc_getClass("FBMobileConfigUserSessionContextManager");
    if (expected && ![manager isKindOfClass:expected]) return NO;
    if (!expected && ![NSStringFromClass([manager class]) containsString:@"UserSessionContextManager"]) return NO;

    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    return method && method_getNumberOfArguments(method) == 3 &&
           WAGRMCRuntimeArgumentFitsWord(method, 2) &&
           (WAGRMCRuntimeReturnsObject(method) || WAGRMCRuntimeReturnsInteger(method));
}

static id WAGRMCRuntimeAccountManager(id userContext) {
    // Identity-sensitive crosswalks must never substitute sessionless/default.
    // WAGRMobileConfigUserSessionContextManager now reaches the WAProperties.mc
    // live bridge when the context has no native mobileConfig accessor.
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    if (WAGRMCRuntimeCanResolveStableId(manager)) return manager;
    WAGRLogAppend(@"[MobileConfig][RuntimeResolver] exact UserSession manager unresolved; refusing generic fallback");
    return nil;
}

NSString *WAGRMobileConfigRuntimeNameForSpecifier(uint64_t specifier) {
    if (!specifier) return nil;
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs") ?: objc_getClass("FBMobileConfigStartupConfigs");
    id instance = WAGRMCRuntimeCallClassObjectNoArg(cls, @"getInstance");
    if (!instance) return nil;

    SEL selector = NSSelectorFromString(@"convertSpecifierToParamName:");
    Method method = class_getInstanceMethod([instance class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRMCRuntimeReturnsObject(method) || !WAGRMCRuntimeArgumentFitsWord(method, 2)) return nil;

    @try {
        id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(instance, selector, specifier);
        if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) return nil;
        return value;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

void WAGRMobileConfigRuntimeSplitName(NSString *fullName,
                                      NSString **configName,
                                      NSString **parameterName) {
    if (configName) *configName = nil;
    if (parameterName) *parameterName = nil;
    if (!fullName.length) return;

    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0 && NSMaxRange(dot) < fullName.length) {
        if (configName) *configName = [fullName substringToIndex:dot.location];
        if (parameterName) *parameterName = [fullName substringFromIndex:NSMaxRange(dot)];
    } else if (parameterName) {
        *parameterName = fullName;
    }
}

uint64_t WAGRMobileConfigRuntimeStableIdForSpecifier(id userContext, uint64_t specifier) {
    if (!specifier) return 0;
    id manager = WAGRMCRuntimeAccountManager(userContext);
    if (!manager) return 0;

    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRMCRuntimeArgumentFitsWord(method, 2)) return 0;

    @try {
        uint64_t value = 0;
        if (WAGRMCRuntimeReturnsObject(method)) {
            id object = ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            if ([object respondsToSelector:@selector(unsignedLongLongValue)]) {
                value = [object unsignedLongLongValue];
            }
        } else if (WAGRMCRuntimeReturnsInteger(method)) {
            value = ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
        }
        return value;
    } @catch (__unused NSException *exception) {
        return 0;
    }
}
