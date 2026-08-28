#import "WAGRABPropsNativeOverrideEngine.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRMobileConfigRuntimeResolver.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static NSString * const kWAGRABNativeErrorDomain = @"WATweaks.ABPropsNativeOverride";
static NSString * const kWAGRABNativeRegistryKey = @"watweak_native_abprops_override_registry_v3";

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

#pragma mark - Read-only physical override observation

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

#pragma mark - Proven native in-memory writer

static id WAGRABNativeStartupConfigs(void) {
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs") ?: objc_getClass("FBMobileConfigStartupConfigs");
    return WAGRABNativeCallClassObjectNoArg(cls, @"getInstance");
}

static BOOL WAGRABNativeStartupSet(uint64_t specifier, id value, NSString **outDiagnostic) {
    id startup = WAGRABNativeStartupConfigs();
    if (!startup) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigStartupConfigs.getInstance não resolveu.";
        return NO;
    }
    SEL selector = NSSelectorFromString(@"setOverrideForParam:andValue:");
    Method method = class_getInstanceMethod([startup class], selector);
    if (!method || method_getNumberOfArguments(method) != 4 || !WAGRABNativeMethodReturnsVoid(method) ||
        !WAGRABNativeArgumentIsWord(method, 2) || !WAGRABNativeArgumentIsObject(method, 3)) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigStartupConfigs setOverrideForParam:andValue: ABI incompatível.";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, uint64_t, id))objc_msgSend)(startup, selector, specifier, value);
        if (outDiagnostic) *outDiagnostic = @"StartupConfigs setOverrideForParam:andValue: aplicado.";
        return YES;
    } @catch (NSException *exception) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"StartupConfigs set lançou %@", exception.reason ?: @"exception"];
        return NO;
    }
}

static BOOL WAGRABNativeStartupRemove(uint64_t specifier, NSString **outDiagnostic) {
    id startup = WAGRABNativeStartupConfigs();
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
        if (outDiagnostic) *outDiagnostic = @"StartupConfigs removeOverrideForParam: aplicado.";
        return YES;
    } @catch (NSException *exception) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"StartupConfigs remove lançou %@", exception.reason ?: @"exception"];
        return NO;
    }
}

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

    // The current SharedModules ABI returns an Objective-C object from
    // getStableIdFromParamSpecifier:.  RuntimeResolver owns that ABI detail.
    uint64_t externalID = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext, specifier);
    if (!externalID) {
        if (outDiagnostic) *outDiagnostic = @"UserSession não resolveu external config stable ID para este paramSpecifier.";
        return nil;
    }

    uint16_t parameterIndex = (uint16_t)((specifier >> 16) & 0xFFFF);
    uint8_t nativeType = (uint8_t)((specifier >> 48) & 0x3F);
    NSString *fullName = WAGRMobileConfigRuntimeNameForSpecifier(specifier);
    NSString *configName = nil, *parameterName = nil;
    WAGRMobileConfigRuntimeSplitName(fullName, &configName, &parameterName);
    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    NSMutableDictionary *result = [@{
        @"wa_stable_id" : @(waID),
        @"param_specifier" : @(specifier),
        @"param_specifier_hex" : [NSString stringWithFormat:@"0x%016llx", specifier],
        @"external_config_stable_id" : @(externalID),
        @"parameter_index" : @(parameterIndex),
        @"native_type" : @(nativeType),
        @"manager_class" : NSStringFromClass([manager class]) ?: @"?",
        @"overrides_path" : path ?: @""
    } mutableCopy];
    if (configName.length) result[@"config_name"] = configName;
    if (parameterName.length) result[@"parameter_name"] = parameterName;
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
        @"AB %@ -> specifier 0x%016llx -> external MC %llu / param %u (%@.%@)",
        waStableID, specifier, externalID, parameterIndex, configName ?: @"?", parameterName ?: @"?"];
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
        ? [NSString stringWithFormat:@"%@; physical mc_overrides observation=%@ (read-only, not the ABProps writer)", mappingDiagnostic ?: @"", row]
        : [NSString stringWithFormat:@"%@; physical mc_overrides observation=none", mappingDiagnostic ?: @""];
    return row;
}

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

    uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
    NSString *startupDiagnostic = nil;
    BOOL startupOK = WAGRABNativeStartupSet(specifier, normalized, &startupDiagnostic);
    if (!startupOK) {
        if (outError) *outError = WAGRABNativeError(3, startupDiagnostic ?: @"StartupConfigs set failed.");
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; %@", mappingDiagnostic ?: @"", startupDiagnostic ?: @"set failed"];
        return NO;
    }

    WAGRABNativeRegistrySet(waStableID, normalized);

    // Invalidation is a live ObjC API with a safe no-arg ABI.  The main
    // FBMobileConfigOverridesTable serializer remains unresolved, so this path
    // deliberately does not synthesize/write mc_overrides.json.
    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = WAGRMobileConfigNativeInvalidate(userContext, &invalidateDiagnostic);
    NSString *refreshDiagnostic = nil;
    BOOL refreshed = WAGRABPropsNativeRefreshMobileConfig(waStableID, userContext, &refreshDiagnostic);

    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
        @"%@; startup=%@; nativeInvalidate=%@ (%@); targetedRefresh=%@ (%@); diskWriter=disabled-until-main-serializer-proven",
        mappingDiagnostic ?: @"", startupDiagnostic ?: @"ok",
        invalidated ? @"YES" : @"NO", invalidateDiagnostic ?: @"",
        refreshed ? @"YES" : @"NO", refreshDiagnostic ?: @""];
    return YES;
}

BOOL WAGRABPropsNativeClearOverride(NSString *waStableID, id userContext,
                                    NSError **outError, NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext, &mappingDiagnostic);
    if (!mapping) {
        if (outError) *outError = WAGRABNativeError(4, mappingDiagnostic);
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return NO;
    }

    uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
    NSString *startupDiagnostic = nil;
    BOOL startupOK = WAGRABNativeStartupRemove(specifier, &startupDiagnostic);
    if (!startupOK) {
        if (outError) *outError = WAGRABNativeError(5, startupDiagnostic ?: @"StartupConfigs remove failed.");
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; %@", mappingDiagnostic ?: @"", startupDiagnostic ?: @"remove failed"];
        return NO;
    }

    WAGRABNativeRegistrySet(waStableID, nil);
    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = WAGRMobileConfigNativeInvalidate(userContext, &invalidateDiagnostic);
    NSString *refreshDiagnostic = nil;
    BOOL refreshed = WAGRABPropsNativeRefreshMobileConfig(waStableID, userContext, &refreshDiagnostic);

    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:
        @"%@; startup=%@; nativeInvalidate=%@ (%@); targetedRefresh=%@ (%@); physical mc_overrides untouched by design",
        mappingDiagnostic ?: @"", startupDiagnostic ?: @"ok",
        invalidated ? @"YES" : @"NO", invalidateDiagnostic ?: @"",
        refreshed ? @"YES" : @"NO", refreshDiagnostic ?: @""];
    return YES;
}

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
        } else if (failures.count < 8) {
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
        } else if (failures.count < 8) {
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
            @"%@; forceRefreshOfConfig:%llu solicitado ao UserSession manager; backend real deve ser confirmado pelo observer XWA2/WWW.",
            mappingDiagnostic ?: @"", external];
        return YES;
    } @catch (NSException *exception) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"forceRefreshOfConfig lançou %@", exception.reason ?: @"exception"];
        return NO;
    }
}
