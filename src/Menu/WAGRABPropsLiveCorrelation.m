#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "WAGRABPropsBrowserVC.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"

static NSDictionary *(*orig_WAGRABNativeEntryForRuntimeEntry)(id, SEL, WAGRABPropEntry *) = NULL;

static const char *WAGRABLiveCorrSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABLiveCorrWordArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRABLiveCorrSkipQualifiers(raw);
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRABLiveCorrWordReturn(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRABLiveCorrSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static uint64_t WAGRABLiveCorrMCSpecifier(unsigned long long stableID) {
    Class cls = NSClassFromString(@"WAMCEvaluation") ?: objc_getClass("WAMCEvaluation");
    SEL selector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABLiveCorrWordArgument(method, 2) || !WAGRABLiveCorrWordReturn(method)) return 0;
    @try {
        return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)cls, selector, stableID);
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static void WAGRABLiveCorrSplitName(NSString *full, NSString **config, NSString **parameter) {
    WAGRMobileConfigRuntimeSplitName(full, config, parameter);
}

static NSDictionary *WAGRABLiveCorrMC(unsigned long long stableID, id userContext) {
    uint64_t specifier = WAGRABLiveCorrMCSpecifier(stableID);
    if (!specifier || (specifier & (1ULL << 62))) return nil;

    uint64_t external = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext, specifier);
    NSString *fullName = WAGRMobileConfigRuntimeNameForSpecifier(specifier);
    NSString *configName = nil, *parameterName = nil;
    WAGRABLiveCorrSplitName(fullName, &configName, &parameterName);

    NSMutableDictionary *mc = [@{
        @"param_specifier_hex": [NSString stringWithFormat:@"0x%016llx", specifier],
        @"local_config_index": @((specifier >> 32) & 0xFFFF),
        @"parameter_index": @((specifier >> 16) & 0xFFFF),
        @"compact_parameter_token": @(specifier & 0xFFFF),
        @"native_type": @((specifier >> 48) & 0x3F),
        @"identity_source": @"live IMP stable ID + WAMCEvaluation",
    } mutableCopy];
    if (external) mc[@"config_stable_id"] = @(external);
    if (configName.length) mc[@"config_name"] = configName;
    if (parameterName.length) mc[@"parameter_name"] = parameterName;
    return mc;
}

static id WAGRABLiveCorrKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static NSDictionary *WAGRABLiveNativeEntry(id self, SEL _cmd, WAGRABPropEntry *entry) {
    if (!entry) return orig_WAGRABNativeEntryForRuntimeEntry
        ? orig_WAGRABNativeEntryForRuntimeEntry(self, _cmd, entry) : nil;

    NSString *stableID = WAGRABPropsStableIDForTarget(entry.className,
                                                       entry.selectorName,
                                                       entry.classMethod);
    if (!stableID.length) {
        return orig_WAGRABNativeEntryForRuntimeEntry
            ? orig_WAGRABNativeEntryForRuntimeEntry(self, _cmd, entry) : nil;
    }

    WAGRABPropsNativeSnapshot *snapshot = WAGRABLiveCorrKVC(self, @"nativeSnapshot");
    id raw = snapshot.props[stableID];
    if (!raw) raw = snapshot.props[@(stableID.longLongValue)];
    id value = [raw isKindOfClass:NSDictionary.class] && raw[@"value"] ? raw[@"value"] : raw;
    id context = WAGRABLiveCorrKVC(self, @"userContext");
    NSDictionary *mc = WAGRABLiveCorrMC(stableID.longLongValue, context);

    NSMutableDictionary *result = [@{
        @"code": @(stableID.longLongValue),
        @"name": entry.selectorName ?: [NSString stringWithFormat:@"ABProp %@", stableID],
        @"value": value ?: (id)NSNull.null,
        @"native_entry": raw ?: (id)NSNull.null,
        @"identity_source": @"live getter IMP",
    } mutableCopy];
    if (mc) result[@"mobileconfig"] = mc;
    return result;
}

static void WAGRABLiveCorrInstall(void) {
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    SEL selector = NSSelectorFromString(@"nativeEntryForRuntimeEntry:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRABLiveNativeEntry) return;
    orig_WAGRABNativeEntryForRuntimeEntry =
        (NSDictionary *(*)(id, SEL, WAGRABPropEntry *))current;
    method_setImplementation(method, (IMP)WAGRABLiveNativeEntry);
}

__attribute__((constructor))
static void WAGRABPropsLiveCorrelationCtor(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRABLiveCorrInstall(); });
    }
}
