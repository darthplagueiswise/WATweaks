#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <string.h>

static NSString *(*orig_WAGRMCParameterName)(WAGRMobileConfigMapping *, SEL) = NULL;
static NSString *(*orig_WAGRMCConfigName)(WAGRMobileConfigMapping *, SEL) = NULL;
static BOOL gWAGRMCNameHooksInstalled = NO;
static const void *kWAGRMCEmbeddedNameCacheKey = &kWAGRMCEmbeddedNameCacheKey;
static const void *kWAGRMCEmbeddedNameMissKey = &kWAGRMCEmbeddedNameMissKey;

static BOOL WAGRMCNameMethodReturnsObject(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char type[32] = {0};
    method_getReturnType(method, type, sizeof(type));
    const char *cursor = type;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor == '@';
}

static NSString *WAGRMCEmbeddedSpecifierName(WAGRMobileConfigMapping *mapping) {
    if (!mapping || !mapping.paramSpecifier) return nil;
    NSString *cached = objc_getAssociatedObject(mapping, kWAGRMCEmbeddedNameCacheKey);
    if (cached.length) return cached;
    if ([objc_getAssociatedObject(mapping, kWAGRMCEmbeddedNameMissKey) boolValue]) return nil;

    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs");
    if (!cls) return nil;

    SEL getInstance = NSSelectorFromString(@"getInstance");
    Method classMethod = class_getClassMethod(cls, getInstance);
    if (!WAGRMCNameMethodReturnsObject(classMethod)) return nil;

    id instance = nil;
    @try { instance = ((id (*)(id, SEL))objc_msgSend)((id)cls, getInstance); }
    @catch (__unused NSException *exception) { instance = nil; }
    if (!instance) return nil;

    SEL convert = NSSelectorFromString(@"convertSpecifierToParamName:");
    Method method = class_getInstanceMethod([instance class], convert);
    if (!method || method_getNumberOfArguments(method) != 3) return nil;
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *cursor = returnType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    if (*cursor != '@') return nil;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    cursor = argumentType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(cursor, &size, &alignment); }
    @catch (__unused NSException *exception) { return nil; }
    if (!size || size > sizeof(uint64_t)) return nil;

    id value = nil;
    @try {
        value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(instance,
                                                          convert,
                                                          mapping.paramSpecifier);
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) {
        objc_setAssociatedObject(mapping, kWAGRMCEmbeddedNameMissKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    objc_setAssociatedObject(mapping, kWAGRMCEmbeddedNameCacheKey, value,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return value;
}

static void WAGRMCParseEmbeddedName(NSString *fullName,
                                    NSString **configName,
                                    NSString **parameterName) {
    if (configName) *configName = nil;
    if (parameterName) *parameterName = nil;
    if (!fullName.length) return;

    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0 && NSMaxRange(dot) < fullName.length) {
        if (configName) *configName = [fullName substringToIndex:dot.location];
        if (parameterName) *parameterName = [fullName substringFromIndex:NSMaxRange(dot)];
        return;
    }

    // Some Meta snapshots serialize with '/' instead of '.'. Keep the complete
    // native string as parameter name if no safe config/param split is present.
    if (parameterName) *parameterName = fullName;
}

static NSString *hook_WAGRMCParameterName(WAGRMobileConfigMapping *self, SEL _cmd) {
    NSString *native = orig_WAGRMCParameterName ? orig_WAGRMCParameterName(self, _cmd) : nil;
    if (native.length) return native;
    NSString *embedded = WAGRMCEmbeddedSpecifierName(self);
    NSString *parameter = nil;
    WAGRMCParseEmbeddedName(embedded, NULL, &parameter);
    return parameter;
}

static NSString *hook_WAGRMCConfigName(WAGRMobileConfigMapping *self, SEL _cmd) {
    NSString *native = orig_WAGRMCConfigName ? orig_WAGRMCConfigName(self, _cmd) : nil;
    if (native.length) return native;
    NSString *embedded = WAGRMCEmbeddedSpecifierName(self);
    NSString *config = nil;
    WAGRMCParseEmbeddedName(embedded, &config, NULL);
    return config;
}

__attribute__((constructor))
static void WAGRMobileConfigNameEnrichmentCtor(void) {
    @autoreleasepool {
        if (gWAGRMCNameHooksInstalled) return;
        Class cls = NSClassFromString(@"WAGRMobileConfigMapping");
        if (!cls) return;
        Method parameterMethod = class_getInstanceMethod(cls, @selector(parameterName));
        Method configMethod = class_getInstanceMethod(cls, @selector(configName));
        if (WAGRMCNameMethodReturnsObject(parameterMethod)) {
            MSHookMessageEx(cls, @selector(parameterName),
                            (IMP)hook_WAGRMCParameterName,
                            (IMP *)&orig_WAGRMCParameterName);
        }
        if (WAGRMCNameMethodReturnsObject(configMethod)) {
            MSHookMessageEx(cls, @selector(configName),
                            (IMP)hook_WAGRMCConfigName,
                            (IMP *)&orig_WAGRMCConfigName);
        }
        gWAGRMCNameHooksInstalled = (orig_WAGRMCParameterName != NULL ||
                                     orig_WAGRMCConfigName != NULL);
        if (gWAGRMCNameHooksInstalled) {
            WAGRLogAppend(@"[MobileConfig] native specifier-name enrichment installed");
        }
    }
}
