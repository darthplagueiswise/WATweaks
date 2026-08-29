#import "WAGRABPropsNativeOverrideEngine.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRMobileConfigRuntimeResolver.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static NSString * const kWAGRABNativeErrorDomain = @"WATweaks.ABPropsNativeOverride";
static NSString * const kWAGRABNativeRegistryKey = @"watweak_native_abprops_override_registry_v3";
static NSString * const kWAGRStartupOverrideKeyPrefix = @"FBMobileConfigStartupConfigsOverride";

static const char *WAGRABNativeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABNativeWordType(const char *type) {
    switch (WAGRABNativeSkipQualifiers(type)[0]) {
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q': return YES;
        default: return NO;
    }
}

static BOOL WAGRABNativeMethodReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABNativeSkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRABNativeMethodReturnsBool(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRABNativeSkipQualifiers(raw);
    return type[0] == 'B' || type[0] == 'c' || type[0] == 'C';
}

static BOOL WAGRABNativeMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABNativeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABNativeArgumentIsWord(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[128] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRABNativeSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRABNativeArgumentIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRABNativeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABNativeWordToWordMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char result[64] = {0};
    method_getReturnType(method, result, sizeof(result));
    return WAGRABNativeWordType(result) && WAGRABNativeArgumentIsWord(method, 2);
}

static id WAGRABNativeCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRABNativeMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABNativeCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRABNativeMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static uint64_t WAGRABNativeParseStableID(NSString *stableID) {
    if (![stableID isKindOfClass:NSString.class] || !stableID.length) return 0;
    const char *bytes = stableID.UTF8String;
    if (!bytes || !*bytes) return 0;
    char *end = NULL;
    unsigned long long value = strtoull(bytes, &end, 10);
    if (!value || end == bytes || (end && *end != '\0')) return 0;
    return (uint64_t)value;
}

static NSError *WAGRABNativeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kWAGRABNativeErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey : message ?: @"ABProps native override error"}];
}

static uint64_t WAGRABNativeSpecifier(uint64_t waStableID) {
    Class cls = NSClassFromString(@"WAMCEvaluation") ?: objc_getClass("WAMCEvaluation");
    SEL selector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!cls || !WAGRABNativeWordToWordMethod(method)) return 0;
    @try { return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)cls, selector, waStableID); }
    @catch (__unused NSException *exception) { return 0; }
}

#pragma mark - Physical mc_overrides observation (read-only)

static NSDictionary *WAGRABNativeReadOverrideDocument(id userContext) {
    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    if (!path.length) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSString *WAGRABNativeStablePrefix(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return nil;
    NSString *prefix = [[key componentsSeparatedByString:@":"] firstObject];
    NSString *trimmed = [prefix stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return trimmed.length ? trimmed : nil;
}

static NSInteger WAGRABNativeRowIndex(NSString *row) {
    if (![row isKindOfClass:NSString.class]) return NSNotFound;
    NSString *prefix = [[row componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return NSNotFound;
    NSCharacterSet *bad = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    if ([prefix rangeOfCharacterFromSet:bad].location != NSNotFound) return NSNotFound;
    return prefix.integerValue;
}

#pragma mark - WATweaks intent registry

static NSObject *WAGRABNativeRegistryLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, id> *WAGRABNativeMutableRegistry(void) {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kWAGRABNativeRegistryKey];
    return [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static void WAGRABNativeRegistrySet(NSString *stableID, id value) {
    if (!stableID.length) return;
    @synchronized (WAGRABNativeRegistryLock()) {
        NSMutableDictionary *registry = WAGRABNativeMutableRegistry();
        if (value) registry[stableID] = value; else [registry removeObjectForKey:stableID];
        [[NSUserDefaults standardUserDefaults] setObject:registry forKey:kWAGRABNativeRegistryKey];
    }
}

NSDictionary<NSString *, id> *WAGRABPropsNativeTrackedOverrides(void) {
    @synchronized (WAGRABNativeRegistryLock()) { return [WAGRABNativeMutableRegistry() copy]; }
}

NSArray<NSNumber *> *WAGRABPropsNativeTrackedStableIDs(void) {
    NSDictionary *registry = WAGRABPropsNativeTrackedOverrides();
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:registry.count];
    for (NSString *key in registry) {
        uint64_t stable = WAGRABNativeParseStableID(key);
        if (stable) [values addObject:@(stable)];
    }
    [values sortUsingSelector:@selector(compare:)];
    return values;
}

void WAGRABPropsNativeRememberTrackedOverride(NSString *waStableID, id value) {
    WAGRABNativeRegistrySet(waStableID, value);
}

void WAGRABPropsNativeForgetTrackedOverride(NSString *waStableID) {
    WAGRABNativeRegistrySet(waStableID, nil);
}

void WAGRABPropsNativeForgetAllTrackedOverrides(void) {
    @synchronized (WAGRABNativeRegistryLock()) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kWAGRABNativeRegistryKey];
    }
}

#pragma mark - Type normalization/equality

static id WAGRABNativeNormalizeValue(id value, uint8_t nativeType) {
    if (!value || value == NSNull.null) return nil;
    switch (nativeType) {
        case 1: return [value respondsToSelector:@selector(boolValue)] ? @([value boolValue]) : nil;
        case 2: return [value respondsToSelector:@selector(longLongValue)] ? @([value longLongValue]) : nil;
        case 3: {
            if ([value isKindOfClass:NSString.class]) return value;
            if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
                if (![NSJSONSerialization isValidJSONObject:value]) return nil;
                NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            }
            return [value description];
        }
        case 4: return [value respondsToSelector:@selector(doubleValue)] ? @([value doubleValue]) : nil;
        default: return nil;
    }
}

static BOOL WAGRABNativeValuesEqual(id left, id right, uint8_t nativeType) {
    id a = WAGRABNativeNormalizeValue(left, nativeType);
    id b = WAGRABNativeNormalizeValue(right, nativeType);
    if (!a || !b) return NO;
    switch (nativeType) {
        case 1: return [a boolValue] == [b boolValue];
        case 2: return [a longLongValue] == [b longLongValue];
        case 3: return [a isEqual:b];
        case 4: {
            double av = [a doubleValue], bv = [b doubleValue];
            if (isnan(av) && isnan(bv)) return YES;
            return av == bv;
        }
        default: return NO;
    }
}

static NSString *WAGRABNativeValueString(id value, uint8_t nativeType) {
    id normalized = WAGRABNativeNormalizeValue(value, nativeType);
    if (!normalized) return nil;
    if (nativeType == 1) return [normalized boolValue] ? @"true" : @"false";
    if (nativeType == 2) return [NSString stringWithFormat:@"%lld", [normalized longLongValue]];
    if (nativeType == 4) return [NSString stringWithFormat:@"%.17g", [normalized doubleValue]];
    return [normalized isKindOfClass:NSString.class] ? normalized : [normalized description];
}

#pragma mark - Native StartupConfigs writer + exact backing store

static id WAGRABNativeStartupConfigs(void) {
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs") ?: objc_getClass("FBMobileConfigStartupConfigs");
    return WAGRABNativeCallClassObjectNoArg(cls, @"getInstance");
}

static NSUserDefaults *WAGRABNativeStartupSharedDefaults(void) {
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigsDeprecated") ?:
                objc_getClass("FBMobileConfigStartupConfigsDeprecated");
    id defaults = WAGRABNativeCallClassObjectNoArg(cls, @"sharedUserDefaultsForTesting");
    return [defaults isKindOfClass:NSUserDefaults.class] ? defaults : nil;
}

static NSString *WAGRABNativeStartupParamName(id startup, uint64_t specifier) {
    if (!startup || !specifier) return nil;
    SEL selector = NSSelectorFromString(@"convertSpecifierToParamName:");
    Method method = class_getInstanceMethod([startup class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABNativeArgumentIsWord(method, 2) || !WAGRABNativeMethodReturnsObject(method)) return nil;
    @try {
        id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(startup, selector, specifier);
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static NSDictionary *WAGRABNativeStartupLiveOverrides(id startup) {
    id value = WAGRABNativeCallObjectNoArg(startup, @"configValuesOverride");
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static NSDictionary *WAGRABNativeStartupPersistentProbe(NSString *paramName,
                                                         id expectedValue,
                                                         uint8_t nativeType) {
    NSUserDefaults *defaults = WAGRABNativeStartupSharedDefaults();
    if (!defaults) return @{
        @"available": @NO,
        @"reason": @"FBMobileConfigStartupConfigsDeprecated.sharedUserDefaultsForTesting unresolved"
    };
    NSDictionary *representation = [defaults dictionaryRepresentation] ?: @{};
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    [representation enumerateKeysAndObjectsUsingBlock:^(id key, __unused id obj, __unused BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [(NSString *)key hasPrefix:kWAGRStartupOverrideKeyPrefix]) {
            [keys addObject:key];
        }
    }];
    [keys sortUsingSelector:@selector(compare:)];

    NSString *matchedKey = nil;
    id observed = nil;
    BOOL present = NO;
    BOOL valueMatches = NO;
    for (NSString *key in keys) {
        NSDictionary *dictionary = [defaults dictionaryForKey:key];
        if (![dictionary isKindOfClass:NSDictionary.class]) continue;
        id candidate = paramName.length ? dictionary[paramName] : nil;
        if (!candidate) continue;
        present = YES;
        observed = candidate;
        if (!expectedValue || WAGRABNativeValuesEqual(candidate, expectedValue, nativeType)) {
            matchedKey = key;
            valueMatches = expectedValue ? YES : NO;
            if (expectedValue) break;
        }
    }

    return @{
        @"available": @YES,
        @"suite_class": NSStringFromClass([defaults class]) ?: @"?",
        @"candidate_keys": keys,
        @"parameter_name": paramName ?: @"",
        @"present": @(present),
        @"matched_key": matchedKey ?: (id)NSNull.null,
        @"observed_value": observed ?: (id)NSNull.null,
        @"value_matches": @(valueMatches)
    };
}

static BOOL WAGRABNativeStartupSet(id startup,
                                    uint64_t specifier,
                                    id value,
                                    BOOL *outNativeBoolResult,
                                    NSString **outDiagnostic) {
    if (outNativeBoolResult) *outNativeBoolResult = NO;
    if (!startup) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigStartupConfigs.getInstance não resolveu.";
        return NO;
    }
    SEL selector = NSSelectorFromString(@"setOverrideForParam:andValue:");
    Method method = class_getInstanceMethod([startup class], selector);
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRABNativeArgumentIsWord(method, 2) || !WAGRABNativeArgumentIsObject(method, 3) ||
        (!WAGRABNativeMethodReturnsBool(method) && !WAGRABNativeMethodReturnsVoid(method))) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigStartupConfigs setOverrideForParam:andValue: ABI incompatível.";
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    @try {
        if (WAGRABNativeMethodReturnsBool(method)) {
            BOOL accepted = ((BOOL (*)(id, SEL, uint64_t, id))objc_msgSend)(startup, selector, specifier, value);
            if (outNativeBoolResult) *outNativeBoolResult = accepted;
            if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
                @"setOverrideForParam:andValue: ABI=%s returned=%@", encoding ?: "?", accepted ? @"YES" : @"NO"];
            return accepted;
        }
        ((void (*)(id, SEL, uint64_t, id))objc_msgSend)(startup, selector, specifier, value);
        if (outNativeBoolResult) *outNativeBoolResult = YES;
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
            @"setOverrideForParam:andValue: legacy ABI=%s invoked", encoding ?: "?"];
        return YES;
    } @catch (NSException *exception) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"StartupConfigs set lançou %@", exception.reason ?: @"exception"];
        return NO;
    }
}

static BOOL WAGRABNativeStartupRemove(id startup, uint64_t specifier, NSString **outDiagnostic) {
    if (!startup) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigStartupConfigs.getInstance não resolveu.";
        return NO;
    }
    SEL selector = NSSelectorFromString(@"removeOverrideForParam:");
    Method method = class_getInstanceMethod([startup class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRABNativeMethodReturnsVoid(method) ||
        !WAGRABNativeArgumentIsWord(method, 2)) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigStartupConfigs removeOverrideForParam: ABI incompatível.";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(startup, selector, specifier);
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"removeOverrideForParam: ABI=%s invoked",
            method_getTypeEncoding(method) ?: "?"];
        return YES;
    } @catch (NSException *exception) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"StartupConfigs remove lançou %@", exception.reason ?: @"exception"];
        return NO;
    }
}

static WAGRMobileConfigMapping *WAGRABNativeMappingObject(NSDictionary *mapping) {
    if (![mapping isKindOfClass:NSDictionary.class]) return nil;
    WAGRMobileConfigMapping *object = [WAGRMobileConfigMapping new];
    object.waStableId = [mapping[@"wa_stable_id"] unsignedIntegerValue];
    object.paramSpecifier = [mapping[@"param_specifier"] unsignedLongLongValue];
    object.localConfigIndex = (uint16_t)((object.paramSpecifier >> 32) & 0xFFFF);
    object.parameterIndex = (uint16_t)((object.paramSpecifier >> 16) & 0xFFFF);
    object.parameterStableId = (uint16_t)(object.paramSpecifier & 0xFFFF);
    object.nativeType = (uint8_t)[mapping[@"native_type"] unsignedIntegerValue];
    object.externalConfigStableId = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
    object.configName = [mapping[@"config_name"] isKindOfClass:NSString.class] ? mapping[@"config_name"] : nil;
    object.parameterName = [mapping[@"parameter_name"] isKindOfClass:NSString.class] ? mapping[@"parameter_name"] : nil;
    return object;
}

static void WAGRABNativeRollback(id startup, uint64_t specifier, BOOL hadPrevious, id previousValue) {
    if (hadPrevious && previousValue) {
        BOOL ignored = NO;
        WAGRABNativeStartupSet(startup, specifier, previousValue, &ignored, NULL);
    } else {
        WAGRABNativeStartupRemove(startup, specifier, NULL);
    }
}

#pragma mark - Mapping / read-only physical mc_overrides row

NSDictionary<NSString *, id> *WAGRABPropsNativeOverrideMapping(NSString *waStableID, id userContext, NSString **outDiagnostic) {
    uint64_t waID = WAGRABNativeParseStableID(waStableID);
    if (!waID) {
        if (outDiagnostic) *outDiagnostic = @"WA stable ID inválido.";
        return nil;
    }
    uint64_t specifier = WAGRABNativeSpecifier(waID);
    if (!specifier || (specifier & (1ULL << 62))) {
        if (outDiagnostic) *outDiagnostic = @"WAMCEvaluation não retornou paramSpecifier válido para este ABProp.";
        return nil;
    }
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    if (!manager) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigUserSessionContextManager exato não resolvido.";
        return nil;
    }

    uint64_t externalID = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext, specifier);
    uint16_t localConfigIndex = (uint16_t)((specifier >> 32) & 0xFFFF);
    uint16_t parameterIndex = (uint16_t)((specifier >> 16) & 0xFFFF);
    uint16_t compactToken = (uint16_t)(specifier & 0xFFFF);
    uint8_t nativeType = (uint8_t)((specifier >> 48) & 0x3F);
    NSString *fullName = WAGRMobileConfigRuntimeNameForSpecifier(specifier);
    NSString *configName = nil, *parameterName = nil;
    WAGRMobileConfigRuntimeSplitName(fullName, &configName, &parameterName);
    id startup = WAGRABNativeStartupConfigs();
    NSString *startupParamName = WAGRABNativeStartupParamName(startup, specifier);
    if (!parameterName.length && startupParamName.length) parameterName = startupParamName;

    NSMutableDictionary *result = [@{
        @"wa_stable_id" : @(waID),
        @"param_specifier" : @(specifier),
        @"param_specifier_hex" : [NSString stringWithFormat:@"0x%016llx", specifier],
        @"local_config_index" : @(localConfigIndex),
        @"parameter_index" : @(parameterIndex),
        @"compact_parameter_token" : @(compactToken),
        @"external_config_stable_id" : @(externalID),
        @"native_type" : @(nativeType),
        @"manager_class" : NSStringFromClass([manager class]) ?: @"?",
        @"startup_parameter_name" : startupParamName ?: @"",
        @"overrides_path" : WAGRMobileConfigOverridesPath(userContext) ?: @""
    } mutableCopy];
    if (configName.length) result[@"config_name"] = configName;
    if (parameterName.length) result[@"parameter_name"] = parameterName;
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
        @"AB %@ -> specifier 0x%016llx -> local=%u param=%u token=%u type=%u -> external MC %@ (%@.%@)",
        waStableID, specifier, localConfigIndex, parameterIndex, compactToken, nativeType,
        externalID ? [NSString stringWithFormat:@"%llu", externalID] : @"unresolved",
        configName ?: @"?", parameterName ?: @"?"];
    return result;
}

static NSString *WAGRABNativeRowForMapping(NSDictionary *mapping, id userContext) {
    uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
    NSInteger parameterIndex = [mapping[@"parameter_index"] integerValue];
    if (!externalID || parameterIndex < 0) return nil;
    NSString *wanted = [NSString stringWithFormat:@"%llu", externalID];
    NSDictionary *document = WAGRABNativeReadOverrideDocument(userContext);
    for (NSString *key in document) {
        if (![WAGRABNativeStablePrefix(key) isEqualToString:wanted]) continue;
        NSArray *rows = [document[key] isKindOfClass:NSArray.class] ? document[key] : @[];
        for (NSString *row in rows) {
            if (WAGRABNativeRowIndex(row) == parameterIndex) return row;
        }
    }
    return nil;
}

NSString *WAGRABPropsNativeOverrideRow(NSString *waStableID, id userContext, NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext, &mappingDiagnostic);
    if (!mapping) {
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return nil;
    }
    NSString *row = WAGRABNativeRowForMapping(mapping, userContext);
    if (outDiagnostic) *outDiagnostic = row.length
        ? [NSString stringWithFormat:@"%@; physical mc_overrides observation=%@ (read-only; separate C++ table)", mappingDiagnostic ?: @"", row]
        : [NSString stringWithFormat:@"%@; physical mc_overrides observation=none", mappingDiagnostic ?: @""];
    return row;
}

#pragma mark - Verified native apply/remove

BOOL WAGRABPropsNativeSetOverride(NSString *waStableID, id value, id userContext,
                                  NSError **outError, NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext, &mappingDiagnostic);
    if (!mapping) {
        if (outError) *outError = WAGRABNativeError(1, mappingDiagnostic);
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return NO;
    }

    uint8_t nativeType = (uint8_t)[mapping[@"native_type"] unsignedIntegerValue];
    id normalized = WAGRABNativeNormalizeValue(value, nativeType);
    if (!normalized) {
        NSString *message = [NSString stringWithFormat:@"Valor incompatível com native_type=%u do WAMCEvaluation.", nativeType];
        if (outError) *outError = WAGRABNativeError(2, message);
        if (outDiagnostic) *outDiagnostic = message;
        return NO;
    }

    id startup = WAGRABNativeStartupConfigs();
    uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
    NSString *paramName = WAGRABNativeStartupParamName(startup, specifier);
    if (!startup || !paramName.length) {
        NSString *message = @"FBMobileConfigStartupConfigs/convertSpecifierToParamName: não resolveu o parâmetro nativo.";
        if (outError) *outError = WAGRABNativeError(3, message);
        if (outDiagnostic) *outDiagnostic = message;
        return NO;
    }

    NSDictionary *beforeLive = WAGRABNativeStartupLiveOverrides(startup);
    id previousValue = beforeLive[paramName];
    BOOL hadPrevious = previousValue != nil;

    BOOL nativeAccepted = NO;
    NSString *setDiagnostic = nil;
    if (!WAGRABNativeStartupSet(startup, specifier, normalized, &nativeAccepted, &setDiagnostic)) {
        NSString *message = setDiagnostic ?: @"StartupConfigs rejeitou o override.";
        if (outError) *outError = WAGRABNativeError(4, message);
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; %@", mappingDiagnostic ?: @"", message];
        return NO;
    }

    NSDictionary *afterLive = WAGRABNativeStartupLiveOverrides(startup);
    id liveValue = afterLive[paramName];
    BOOL liveMatches = WAGRABNativeValuesEqual(liveValue, normalized, nativeType);
    NSDictionary *persistent = WAGRABNativeStartupPersistentProbe(paramName, normalized, nativeType);
    BOOL persisted = [persistent[@"present"] boolValue] && [persistent[@"value_matches"] boolValue];

    if (!nativeAccepted || !liveMatches || !persisted) {
        WAGRABNativeRollback(startup, specifier, hadPrevious, previousValue);
        WAGRMobileConfigNativeInvalidate(userContext, NULL);
        NSString *message = [NSString stringWithFormat:
            @"Override rejected after write: native=%@ live=%@ persisted=%@ backing=%@",
            nativeAccepted ? @"YES" : @"NO", liveMatches ? @"YES" : @"NO", persisted ? @"YES" : @"NO", persistent];
        if (outError) *outError = WAGRABNativeError(5, message);
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; %@; %@", mappingDiagnostic ?: @"", setDiagnostic ?: @"", message];
        return NO;
    }

    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = WAGRMobileConfigNativeInvalidate(userContext, &invalidateDiagnostic);
    WAGRMobileConfigMapping *mappingObject = WAGRABNativeMappingObject(mapping);
    id effective = WAGRMobileConfigCurrentValue(mappingObject, userContext);
    BOOL effectiveMatches = WAGRABNativeValuesEqual(effective, normalized, nativeType);
    if (!invalidated || !effectiveMatches) {
        WAGRABNativeRollback(startup, specifier, hadPrevious, previousValue);
        WAGRMobileConfigNativeInvalidate(userContext, NULL);
        NSString *message = [NSString stringWithFormat:
            @"Override reverted: invalidate=%@ effective=%@ expected=%@",
            invalidated ? @"YES" : @"NO", effective ?: @"nil", normalized];
        if (outError) *outError = WAGRABNativeError(6, message);
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
            @"%@; %@; backing=%@; %@; %@",
            mappingDiagnostic ?: @"", setDiagnostic ?: @"", persistent,
            invalidateDiagnostic ?: @"invalidate failed", message];
        return NO;
    }

    WAGRABNativeRegistrySet(waStableID, normalized);
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
        @"%@; %@; live=YES; persisted=YES key=%@; invalidate=YES; effective=%@; mc_overrides.json untouched",
        mappingDiagnostic ?: @"", setDiagnostic ?: @"",
        persistent[@"matched_key"] ?: @"?", effective ?: @"nil"];
    return YES;
}

BOOL WAGRABPropsNativeClearOverride(NSString *waStableID, id userContext,
                                    NSError **outError, NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext, &mappingDiagnostic);
    if (!mapping) {
        if (outError) *outError = WAGRABNativeError(10, mappingDiagnostic);
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return NO;
    }
    id startup = WAGRABNativeStartupConfigs();
    uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
    uint8_t nativeType = (uint8_t)[mapping[@"native_type"] unsignedIntegerValue];
    NSString *paramName = WAGRABNativeStartupParamName(startup, specifier);
    if (!startup || !paramName.length) {
        NSString *message = @"StartupConfigs/parameter name unresolved.";
        if (outError) *outError = WAGRABNativeError(11, message);
        if (outDiagnostic) *outDiagnostic = message;
        return NO;
    }

    NSDictionary *beforeLive = WAGRABNativeStartupLiveOverrides(startup);
    id previousValue = beforeLive[paramName];
    BOOL hadPrevious = previousValue != nil;
    NSString *removeDiagnostic = nil;
    if (!WAGRABNativeStartupRemove(startup, specifier, &removeDiagnostic)) {
        if (outError) *outError = WAGRABNativeError(12, removeDiagnostic ?: @"remove failed");
        if (outDiagnostic) *outDiagnostic = removeDiagnostic;
        return NO;
    }

    BOOL liveAbsent = WAGRABNativeStartupLiveOverrides(startup)[paramName] == nil;
    NSDictionary *persistent = WAGRABNativeStartupPersistentProbe(paramName, nil, nativeType);
    BOOL persistedAbsent = ![persistent[@"present"] boolValue];
    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = WAGRMobileConfigNativeInvalidate(userContext, &invalidateDiagnostic);
    if (!liveAbsent || !persistedAbsent || !invalidated) {
        if (hadPrevious) {
            BOOL ignored = NO;
            WAGRABNativeStartupSet(startup, specifier, previousValue, &ignored, NULL);
            WAGRMobileConfigNativeInvalidate(userContext, NULL);
        }
        NSString *message = [NSString stringWithFormat:
            @"Remove reverted/failed: liveAbsent=%@ persistedAbsent=%@ invalidate=%@ backing=%@",
            liveAbsent ? @"YES" : @"NO", persistedAbsent ? @"YES" : @"NO", invalidated ? @"YES" : @"NO", persistent];
        if (outError) *outError = WAGRABNativeError(13, message);
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; %@; %@", mappingDiagnostic ?: @"", removeDiagnostic ?: @"", message];
        return NO;
    }

    WAGRABNativeRegistrySet(waStableID, nil);
    WAGRMobileConfigMapping *mappingObject = WAGRABNativeMappingObject(mapping);
    id effective = WAGRMobileConfigCurrentValue(mappingObject, userContext);
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
        @"%@; %@; live override absent; persistent override absent; invalidate=YES; effective baseline now=%@; mc_overrides.json untouched",
        mappingDiagnostic ?: @"", removeDiagnostic ?: @"", effective ?: @"nil"];
    return YES;
}

#pragma mark - Bulk sync/reset

NSInteger WAGRABPropsNativeSyncTrackedOverrides(id userContext, NSString **outDiagnostic) {
    NSDictionary<NSString *, id> *registry = WAGRABPropsNativeTrackedOverrides();
    NSArray<NSString *> *keys = [registry.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        unsigned long long av = strtoull(a.UTF8String ?: "0", NULL, 10);
        unsigned long long bv = strtoull(b.UTF8String ?: "0", NULL, 10);
        if (av < bv) return NSOrderedAscending;
        if (av > bv) return NSOrderedDescending;
        return [a compare:b];
    }];
    NSInteger applied = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (NSString *stableID in keys) {
        NSError *error = nil;
        NSString *diagnostic = nil;
        if (WAGRABPropsNativeSetOverride(stableID, registry[stableID], userContext, &error, &diagnostic)) {
            applied++;
        } else if (failures.count < 12) {
            [failures addObject:[NSString stringWithFormat:@"AB %@: %@", stableID, error.localizedDescription ?: diagnostic ?: @"failed"]];
        }
    }
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"tracked=%lu applied=%ld failures=%lu%@",
        (unsigned long)keys.count, (long)applied, (unsigned long)(keys.count - applied),
        failures.count ? [@"\n" stringByAppendingString:[failures componentsJoinedByString:@"\n"]] : @""];
    return applied;
}

NSInteger WAGRABPropsNativeClearTrackedOverrides(id userContext, NSString **outDiagnostic) {
    NSArray<NSNumber *> *stableIDs = WAGRABPropsNativeTrackedStableIDs();
    NSInteger cleared = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (NSNumber *stable in stableIDs) {
        NSString *stableID = stable.stringValue;
        NSError *error = nil;
        NSString *diagnostic = nil;
        if (WAGRABPropsNativeClearOverride(stableID, userContext, &error, &diagnostic)) {
            cleared++;
        } else if (failures.count < 12) {
            [failures addObject:[NSString stringWithFormat:@"AB %@: %@", stableID, error.localizedDescription ?: diagnostic ?: @"failed"]];
        }
    }
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"tracked=%lu cleared=%ld failures=%lu%@",
        (unsigned long)stableIDs.count, (long)cleared, (unsigned long)(stableIDs.count - cleared),
        failures.count ? [@"\n" stringByAppendingString:[failures componentsJoinedByString:@"\n"]] : @""];
    return cleared;
}

BOOL WAGRABPropsNativeRefreshMobileConfig(NSString *waStableID, id userContext, NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext, &mappingDiagnostic);
    if (!mapping) {
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic ?: @"Mapping ausente.";
        return NO;
    }
    uint64_t external = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
    if (!external || external > UINT32_MAX) {
        if (outDiagnostic) *outDiagnostic = @"External config stable ID inválido para forceRefreshOfConfig:.";
        return NO;
    }
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    SEL selector = NSSelectorFromString(@"forceRefreshOfConfig:");
    Method method = manager ? class_getInstanceMethod([manager class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRABNativeMethodReturnsVoid(method) ||
        !WAGRABNativeArgumentIsWord(method, 2)) {
        if (outDiagnostic) *outDiagnostic = @"UserSession forceRefreshOfConfig: ABI incompatível/ausente.";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(manager, selector, (uint32_t)external);
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
            @"%@; local forceRefreshOfConfig:%llu requested. This is not a server fetch.", mappingDiagnostic ?: @"", external];
        return YES;
    } @catch (NSException *exception) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"forceRefreshOfConfig lançou %@", exception.reason ?: @"exception"];
        return NO;
    }
}

#pragma mark - Native/custom export documents

NSDictionary<NSString *, id> *WAGRABPropsNativeStartupOverrideStoreDocument(void) {
    id startup = WAGRABNativeStartupConfigs();
    NSUserDefaults *defaults = WAGRABNativeStartupSharedDefaults();
    NSDictionary *representation = defaults ? [defaults dictionaryRepresentation] : @{};
    NSMutableDictionary *physical = [NSMutableDictionary dictionary];
    for (NSString *key in representation) {
        if (![key isKindOfClass:NSString.class] || ![key hasPrefix:kWAGRStartupOverrideKeyPrefix]) continue;
        id value = [defaults objectForKey:key];
        if (value) physical[key] = value;
    }
    Method set = startup ? class_getInstanceMethod([startup class], NSSelectorFromString(@"setOverrideForParam:andValue:")) : NULL;
    Method remove = startup ? class_getInstanceMethod([startup class], NSSelectorFromString(@"removeOverrideForParam:")) : NULL;
    return @{
        @"schema" : @"watweaks_native_startupconfig_overrides_v1",
        @"source" : @"FBMobileConfigStartupConfigsDeprecated.sharedUserDefaultsForTesting -> METAAppGroup(app).userDefaults",
        @"startup_class" : startup ? (NSStringFromClass([startup class]) ?: @"?") : @"nil",
        @"set_encoding" : set ? ([NSString stringWithUTF8String:method_getTypeEncoding(set)] ?: @"") : @"missing",
        @"remove_encoding" : remove ? ([NSString stringWithUTF8String:method_getTypeEncoding(remove)] ?: @"") : @"missing",
        @"live_configValuesOverride" : WAGRABNativeStartupLiveOverrides(startup),
        @"persistent_keys" : physical,
        @"note" : @"This is the native local ABProp/MobileConfig StartupConfigs override store. It is separate from the C++ FBMobileConfigOverridesTable mc_overrides.json artifact."
    };
}

NSDictionary<NSString *, id> *WAGRABPropsNativeMCOverridesExportDocument(id userContext,
                                                                          NSDictionary<NSString *, id> **stats) {
    NSDictionary<NSString *, id> *tracked = WAGRABPropsNativeTrackedOverrides();
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *result = [NSMutableDictionary dictionary];
    NSUInteger emitted = 0, skippedMapping = 0, skippedUnverified = 0, skippedExternal = 0;
    for (NSString *stableID in tracked) {
        NSString *diagnostic = nil;
        NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(stableID, userContext, &diagnostic);
        if (!mapping) { skippedMapping++; continue; }
        uint8_t nativeType = (uint8_t)[mapping[@"native_type"] unsignedIntegerValue];
        id expected = WAGRABNativeNormalizeValue(tracked[stableID], nativeType);
        NSString *paramName = mapping[@"startup_parameter_name"];
        if (!expected || !paramName.length) { skippedMapping++; continue; }

        NSDictionary *persistent = WAGRABNativeStartupPersistentProbe(paramName, expected, nativeType);
        id live = WAGRABNativeStartupLiveOverrides(WAGRABNativeStartupConfigs())[paramName];
        WAGRMobileConfigMapping *mappingObject = WAGRABNativeMappingObject(mapping);
        id effective = WAGRMobileConfigCurrentValue(mappingObject, userContext);
        if (![persistent[@"value_matches"] boolValue] ||
            !WAGRABNativeValuesEqual(live, expected, nativeType) ||
            !WAGRABNativeValuesEqual(effective, expected, nativeType)) {
            skippedUnverified++;
            continue;
        }

        uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
        if (!externalID) { skippedExternal++; continue; }
        uint16_t parameterIndex = (uint16_t)[mapping[@"parameter_index"] unsignedIntegerValue];
        NSString *valueString = WAGRABNativeValueString(expected, nativeType);
        if (!valueString.length) { skippedMapping++; continue; }
        NSString *configName = [mapping[@"config_name"] isKindOfClass:NSString.class] ? mapping[@"config_name"] : @"";
        NSString *parameterName = [mapping[@"parameter_name"] isKindOfClass:NSString.class] ? mapping[@"parameter_name"] : @"";
        NSString *key = configName.length
            ? [NSString stringWithFormat:@"%llu:%@", externalID, configName]
            : [NSString stringWithFormat:@"%llu:", externalID];
        NSString *row = parameterName.length
            ? [NSString stringWithFormat:@"%u: %@: %@", parameterIndex, parameterName, valueString]
            : [NSString stringWithFormat:@"%u: : %@", parameterIndex, valueString];
        NSMutableArray *rows = result[key];
        if (!rows) { rows = [NSMutableArray array]; result[key] = rows; }
        [rows addObject:row];
        emitted++;
    }
    [result enumerateKeysAndObjectsUsingBlock:^(__unused NSString *key, NSMutableArray<NSString *> *rows, __unused BOOL *stop) {
        [rows sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger ai = [[[a componentsSeparatedByString:@":"] firstObject] integerValue];
            NSInteger bi = [[[b componentsSeparatedByString:@":"] firstObject] integerValue];
            if (ai < bi) return NSOrderedAscending;
            if (ai > bi) return NSOrderedDescending;
            return [a compare:b];
        }];
    }];
    if (stats) *stats = @{
        @"tracked" : @(tracked.count),
        @"emitted" : @(emitted),
        @"configs" : @(result.count),
        @"skipped_mapping" : @(skippedMapping),
        @"skipped_not_persisted_or_not_effective" : @(skippedUnverified),
        @"skipped_external_config_id_unresolved" : @(skippedExternal)
    };
    return result;
}
