#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#import "WAGRABPropsNativeOverrideEngine.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

// Reconnect the release-build ABProps debug surfaces to the live components
// proven in the supplied WhatsApp/SharedModules binaries:
//
//   AB stable ID
//      -> WAMCEvaluation.getMCSpecifierForStableId:
//      -> FBMobileConfigStartupConfigs.setOverrideForParam:andValue:
//      -> FBMobileConfigUserSessionContextManager invalidation/targeted refresh
//      -> FBMobileConfigManager/DefaultUpdater/FBMobileConfigFetcher
//      -> WAMobileConfigFetcher
//      -> WAMobileConfigGraphQLFetcher (XWA2) OR WWW GraphQL fetcher
//
// The XWA2/WWW hooks below are observers, not synthetic fetch implementations.
// They prove which native backend a manager-triggered refresh actually reaches.
// We never objc_msgSend setOverrides: because its live ABI is
// std::shared_ptr<FBMobileConfigOverridesTable>, and we never fabricate a
// WAMobileConfigFetchInput or GraphQL request.

static NSObject *gWAGRLinkageLock;
static NSMutableArray<NSDictionary *> *gWAGRLinkageEvents;
static NSDictionary *gWAGRLastCapturedDebugOverrides;
static const void *kWAGRDebugOverridesAssociationKey = &kWAGRDebugOverridesAssociationKey;

static id (*gWAGRWAPropertiesInitOriginal)(id, SEL, id, id) = NULL;
static id (*gWAGRWAABPropertiesInitOriginal)(id, SEL, id, id) = NULL;
static void (*gWAGRXWA2FetchOriginal)(id, SEL, id, id) = NULL;
static void (*gWAGRWWWFetchOriginal)(id, SEL, id, BOOL, id) = NULL;

static BOOL gWAGRWAPropertiesInitHooked = NO;
static BOOL gWAGRWAABPropertiesInitHooked = NO;
static BOOL gWAGRXWA2ObserverHooked = NO;
static BOOL gWAGRWWWObserverHooked = NO;
static BOOL gWAGRSyncLinked = NO;
static BOOL gWAGRIDsLinked = NO;
static BOOL gWAGRResetLinked = NO;

static void WAGRLinkageEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRLinkageLock = [NSObject new];
        gWAGRLinkageEvents = [NSMutableArray array];
    });
}

static void WAGRLinkageRecord(NSString *kind, NSDictionary *payload) {
    WAGRLinkageEnsureState();
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:payload ?: @{}];
    event[@"kind"] = kind ?: @"event";
    event[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    @synchronized (gWAGRLinkageLock) {
        [gWAGRLinkageEvents addObject:event];
        if (gWAGRLinkageEvents.count > 128) {
            [gWAGRLinkageEvents removeObjectsInRange:NSMakeRange(0, gWAGRLinkageEvents.count - 128)];
        }
    }
}

static const char *WAGRLinkageSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRLinkageReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRLinkageSkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRLinkageReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRLinkageSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRLinkageReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return strchr("cCsSiIlLqQB", WAGRLinkageSkipQualifiers(raw)[0]) != NULL;
}

static BOOL WAGRLinkageArgObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRLinkageSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRLinkageArgBool(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    char type = WAGRLinkageSkipQualifiers(raw)[0];
    return type == 'B' || type == 'c' || type == 'C';
}

static BOOL WAGRLinkageArgWord(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[128] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRLinkageSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static uintptr_t WAGRLinkageIMPAddress(IMP imp) {
#if __has_include(<ptrauth.h>)
    return (uintptr_t)ptrauth_strip((void *)imp, ptrauth_key_function_pointer);
#else
    return (uintptr_t)imp;
#endif
}

static BOOL WAGRLinkageIMPBelongsToTweak(IMP imp) {
    if (!imp) return NO;
    Dl_info info = {0};
    if (!dladdr((void *)WAGRLinkageIMPAddress(imp), &info) || !info.dli_fname) return NO;
    NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
    return [path containsString:@"WATweaks"];
}

static BOOL WAGRLinkageIsRET(uint32_t instruction) {
    return instruction == 0xD65F03C0u;
}

static BOOL WAGRLinkageIsZeroMove(uint32_t instruction) {
    return instruction == 0xD2800000u || instruction == 0x52800000u;
}

static BOOL WAGRLinkageIsZeroReturnAddress(uintptr_t address, NSUInteger depth) {
    if (!address || depth > 3) return NO;
    const uint32_t *code = (const uint32_t *)address;
    uint32_t first = code[0], second = code[1];
    if (WAGRLinkageIsZeroMove(first) && WAGRLinkageIsRET(second)) return YES;
    if ((first & 0x7C000000u) == 0x14000000u) {
        int32_t imm26 = (int32_t)(first & 0x03FFFFFFu);
        if (imm26 & 0x02000000) imm26 |= (int32_t)0xFC000000u;
        uintptr_t target = address + ((intptr_t)imm26 << 2);
        return WAGRLinkageIsZeroReturnAddress(target, depth + 1);
    }
    return NO;
}

static NSString *WAGRLinkageEncoding(Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"";
}

static id WAGRLinkageObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRLinkageReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRLinkageScalarOrObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    if (WAGRLinkageReturnsObject(method)) return WAGRLinkageObjectNoArg(target, selectorName);
    if (WAGRLinkageReturnsInteger(method)) {
        @try { return @(((long long (*)(id, SEL))objc_msgSend)(target, selector)); }
        @catch (__unused NSException *exception) { return nil; }
    }
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    if (WAGRLinkageSkipQualifiers(raw)[0] == 'd') {
        @try { return @(((double (*)(id, SEL))objc_msgSend)(target, selector)); }
        @catch (__unused NSException *exception) { return nil; }
    }
    return nil;
}

#pragma mark - Capture the release initializer's ignored debugOverrides argument

static void WAGRLinkageCaptureDebugOverrides(id owner, id debugOverrides, NSString *source) {
    WAGRLinkageEnsureState();
    if (![debugOverrides isKindOfClass:NSDictionary.class] || [(NSDictionary *)debugOverrides count] == 0) return;
    if (owner) {
        objc_setAssociatedObject(owner, kWAGRDebugOverridesAssociationKey,
                                 debugOverrides, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    @synchronized (gWAGRLinkageLock) {
        gWAGRLastCapturedDebugOverrides = [debugOverrides copy];
    }
    WAGRLinkageRecord(@"debug_overrides_captured", @{
        @"source": source ?: @"initializer",
        @"count": @([(NSDictionary *)debugOverrides count]),
        @"owner": owner ? (NSStringFromClass([owner class]) ?: @"?") : @"nil"
    });
}

static id WAGRLinkageWAPropertiesInit(id self, SEL _cmd, id store, id debugOverrides) {
    id result = gWAGRWAPropertiesInitOriginal ? gWAGRWAPropertiesInitOriginal(self, _cmd, store, debugOverrides) : self;
    WAGRLinkageCaptureDebugOverrides(result ?: self, debugOverrides,
        @"WAProperties.initWithPropertiesStore:debugOverrides:");
    return result;
}

static id WAGRLinkageWAABPropertiesInit(id self, SEL _cmd, id store, id debugOverrides) {
    id result = gWAGRWAABPropertiesInitOriginal ? gWAGRWAABPropertiesInitOriginal(self, _cmd, store, debugOverrides) : self;
    WAGRLinkageCaptureDebugOverrides(result ?: self, debugOverrides,
        @"WAABProperties.initWithPropertiesStore:debugOverrides:");
    return result;
}

static BOOL WAGRLinkageInstallInitializerObserverForClass(Class cls, IMP replacement, IMP *originalOut) {
    if (!cls || !originalOut) return NO;
    SEL selector = NSSelectorFromString(@"initWithPropertiesStore:debugOverrides:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4 || !WAGRLinkageReturnsObject(method) ||
        !WAGRLinkageArgObject(method, 2) || !WAGRLinkageArgObject(method, 3)) return NO;
    IMP current = method_getImplementation(method);
    if (!current || current == replacement) return current == replacement;
    *originalOut = current;
    method_setImplementation(method, replacement);
    return method_getImplementation(method) == replacement;
}

static NSDictionary *WAGRLinkageMergedDebugOverrides(id userContext) {
    WAGRLinkageEnsureState();
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];

    // WATweaks-owned overrides are durable intent and form the base layer.
    NSDictionary *tracked = WAGRABPropsNativeTrackedOverrides();
    if ([tracked isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:tracked];

    // Preserve any real dictionary that the release initializer received even
    // though the binary's common initializer path drops x3.
    NSDictionary *captured = nil;
    @synchronized (gWAGRLinkageLock) { captured = [gWAGRLastCapturedDebugOverrides copy]; }
    if (captured.count) [merged addEntriesFromDictionary:captured];

    for (NSString *accessor in @[@"abProperties", @"privateABProperties", @"waABProperties", @"properties"]) {
        id owner = WAGRLinkageObjectNoArg(userContext, accessor);
        id associated = owner ? objc_getAssociatedObject(owner, kWAGRDebugOverridesAssociationKey) : nil;
        if ([associated isKindOfClass:NSDictionary.class] && [(NSDictionary *)associated count]) {
            [merged addEntriesFromDictionary:associated];
        }
    }

    // A native/non-empty context implementation wins.  The known WATweaks
    // empty fallback does not erase captured/tracked state.
    id direct = WAGRLinkageObjectNoArg(userContext, @"debugPropOverrides");
    if ([direct isKindOfClass:NSDictionary.class] && [(NSDictionary *)direct count]) {
        [merged addEntriesFromDictionary:direct];
    }
    return [merged copy];
}

static NSString *WAGRLinkageStableIDString(id key) {
    if ([key isKindOfClass:NSNumber.class]) {
        unsigned long long value = [key unsignedLongLongValue];
        return value ? [NSString stringWithFormat:@"%llu", value] : nil;
    }
    if (![key isKindOfClass:NSString.class]) return nil;
    NSString *string = [(NSString *)key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!string.length) return nil;
    const char *bytes = string.UTF8String;
    if (!bytes || !*bytes) return nil;
    char *end = NULL;
    unsigned long long value = strtoull(bytes, &end, 10);
    if (!value || end == bytes || (end && *end != '\0')) return nil;
    return [NSString stringWithFormat:@"%llu", value];
}

static id WAGRLinkageOverrideScalar(id value) {
    if (!value || value == NSNull.null) return nil;
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[@"value", @"boolValue", @"int64Value", @"integerValue", @"doubleValue", @"stringValue"]) {
            id candidate = ((NSDictionary *)value)[key];
            if ([candidate isKindOfClass:NSNumber.class] || [candidate isKindOfClass:NSString.class]) return candidate;
        }
    }
    // WAPBConfigOverrideValue is protobuf-backed in this build.  Use generated
    // ObjC/KVC access only when it resolves; never reinterpret protobuf bytes.
    for (NSString *key in @[@"value", @"boolValue", @"int64Value", @"integerValue", @"doubleValue", @"stringValue"]) {
        @try {
            id candidate = [value valueForKey:key];
            if ([candidate isKindOfClass:NSNumber.class] || [candidate isKindOfClass:NSString.class]) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

#pragma mark - Proven local writer: FBMobileConfigStartupConfigs

static id WAGRLinkageStartupConfigs(void) {
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs") ?: objc_getClass("FBMobileConfigStartupConfigs");
    SEL selector = NSSelectorFromString(@"getInstance");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRLinkageReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRLinkageStartupSet(uint64_t specifier, id value) {
    id startup = WAGRLinkageStartupConfigs();
    SEL selector = NSSelectorFromString(@"setOverrideForParam:andValue:");
    Method method = startup ? class_getInstanceMethod([startup class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4 || !WAGRLinkageReturnsVoid(method) ||
        !WAGRLinkageArgWord(method, 2) || !WAGRLinkageArgObject(method, 3)) return NO;
    @try {
        ((void (*)(id, SEL, uint64_t, id))objc_msgSend)(startup, selector, specifier, value);
        return YES;
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][ReleaseLinkage] StartupConfigs set threw %@", exception.reason ?: @"exception");
        return NO;
    }
}

static BOOL WAGRLinkageStartupRemove(uint64_t specifier) {
    id startup = WAGRLinkageStartupConfigs();
    SEL selector = NSSelectorFromString(@"removeOverrideForParam:");
    Method method = startup ? class_getInstanceMethod([startup class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRLinkageReturnsVoid(method) ||
        !WAGRLinkageArgWord(method, 2)) return NO;
    @try {
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(startup, selector, specifier);
        return YES;
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][ReleaseLinkage] StartupConfigs remove threw %@", exception.reason ?: @"exception");
        return NO;
    }
}

static NSDictionary *WAGRLinkageStartupReadback(void) {
    id startup = WAGRLinkageStartupConfigs();
    if (!startup) return @{ @"resolved": @NO };
    id overrides = WAGRLinkageObjectNoArg(startup, @"configValuesOverride");
    id json = WAGRLinkageObjectNoArg(startup, @"toJSON");
    Method setMethod = class_getInstanceMethod([startup class], NSSelectorFromString(@"setOverrideForParam:andValue:"));
    Method removeMethod = class_getInstanceMethod([startup class], NSSelectorFromString(@"removeOverrideForParam:"));
    return @{
        @"resolved": @YES,
        @"class": NSStringFromClass([startup class]) ?: @"?",
        @"set_encoding": WAGRLinkageEncoding(setMethod),
        @"remove_encoding": WAGRLinkageEncoding(removeMethod),
        @"configValuesOverride_class": overrides ? (NSStringFromClass([overrides class]) ?: @"?") : @"nil",
        @"configValuesOverride_count": [overrides respondsToSelector:@selector(count)] ? @([overrides count]) : @0,
        @"toJSON_class": json ? (NSStringFromClass([json class]) ?: @"?") : @"nil",
        @"toJSON_length": [json respondsToSelector:@selector(length)] ? @([json length]) : @0
    };
}

#pragma mark - Native manager refresh and native network observers

static BOOL WAGRLinkageRefreshConfig(id userContext, uint64_t externalStableID) {
    if (!externalStableID || externalStableID > UINT32_MAX) return NO;
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    SEL selector = NSSelectorFromString(@"forceRefreshOfConfig:");
    Method method = manager ? class_getInstanceMethod([manager class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRLinkageReturnsVoid(method) ||
        !WAGRLinkageArgWord(method, 2)) return NO;
    @try {
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(manager, selector, (uint32_t)externalStableID);
        WAGRLinkageRecord(@"manager_targeted_refresh_requested", @{
            @"manager": NSStringFromClass([manager class]) ?: @"?",
            @"external_config_stable_id": @(externalStableID),
            @"encoding": WAGRLinkageEncoding(method)
        });
        return YES;
    } @catch (NSException *exception) {
        WAGRLinkageRecord(@"manager_targeted_refresh_failed", @{
            @"external_config_stable_id": @(externalStableID),
            @"exception": exception.reason ?: @"exception"
        });
        return NO;
    }
}

static NSDictionary *WAGRLinkageXWA2InputSnapshot(id input) {
    if (!input) return @{};
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithObject:(NSStringFromClass([input class]) ?: @"?") forKey:@"input_class"];
    for (NSString *selector in @[@"unitType", @"apiVersion", @"fetchType", @"globalValueHash", @"epRefreshId",
                                 @"unitId", @"queryString", @"batchSize", @"blnLiHashes", @"blnQueries", @"boolOptPolicy"]) {
        id value = WAGRLinkageScalarOrObjectNoArg(input, selector);
        if (value) snapshot[selector] = ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) ? value : ([value description] ?: @"?");
    }
    return snapshot;
}

static void WAGRLinkageXWA2Fetch(id self, SEL _cmd, id input, id completion) {
    NSDictionary *snapshot = WAGRLinkageXWA2InputSnapshot(input);
    WAGRLinkageRecord(@"xwa2_native_fetch_observed", snapshot);
    WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] XWA2 native fetch observed %@", snapshot);
    if (gWAGRXWA2FetchOriginal) gWAGRXWA2FetchOriginal(self, _cmd, input, completion);
}

static void WAGRLinkageWWWFetch(id self, SEL _cmd, id input, BOOL sessionless, id completion) {
    WAGRLinkageRecord(@"www_native_fetch_observed", @{
        @"input_class": input ? (NSStringFromClass([input class]) ?: @"?") : @"nil",
        @"sessionless": @(sessionless)
    });
    WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] WWW native fetch observed sessionless=%@ input=%@",
                   sessionless ? @"YES" : @"NO", input ? NSStringFromClass([input class]) : @"nil");
    if (gWAGRWWWFetchOriginal) gWAGRWWWFetchOriginal(self, _cmd, input, sessionless, completion);
}

static void WAGRLinkageInstallFetchObservers(void) {
    Class xwa = NSClassFromString(@"WAMobileConfigGraphQLFetcher") ?: objc_getClass("WAMobileConfigGraphQLFetcher");
    SEL xwaSel = NSSelectorFromString(@"fetchConfigsWithInput:completion:");
    Method xwaMethod = xwa ? class_getInstanceMethod(xwa, xwaSel) : NULL;
    if (!gWAGRXWA2ObserverHooked && xwaMethod && method_getNumberOfArguments(xwaMethod) == 4 &&
        WAGRLinkageReturnsVoid(xwaMethod) && WAGRLinkageArgObject(xwaMethod, 2) && WAGRLinkageArgObject(xwaMethod, 3)) {
        IMP current = method_getImplementation(xwaMethod);
        if (current && current != (IMP)WAGRLinkageXWA2Fetch) {
            gWAGRXWA2FetchOriginal = (void (*)(id, SEL, id, id))current;
            method_setImplementation(xwaMethod, (IMP)WAGRLinkageXWA2Fetch);
        }
        gWAGRXWA2ObserverHooked = method_getImplementation(xwaMethod) == (IMP)WAGRLinkageXWA2Fetch;
    }

    Class www = NSClassFromString(@"WAMobileConfigWWWGraphQLFetcher") ?: objc_getClass("WAMobileConfigWWWGraphQLFetcher");
    SEL wwwSel = NSSelectorFromString(@"fetchMetaConfigWithInput:isSessionless:completion:");
    Method wwwMethod = www ? class_getInstanceMethod(www, wwwSel) : NULL;
    if (!gWAGRWWWObserverHooked && wwwMethod && method_getNumberOfArguments(wwwMethod) == 5 &&
        WAGRLinkageReturnsVoid(wwwMethod) && WAGRLinkageArgObject(wwwMethod, 2) &&
        WAGRLinkageArgBool(wwwMethod, 3) && WAGRLinkageArgObject(wwwMethod, 4)) {
        IMP current = method_getImplementation(wwwMethod);
        if (current && current != (IMP)WAGRLinkageWWWFetch) {
            gWAGRWWWFetchOriginal = (void (*)(id, SEL, id, BOOL, id))current;
            method_setImplementation(wwwMethod, (IMP)WAGRLinkageWWWFetch);
        }
        gWAGRWWWObserverHooked = method_getImplementation(wwwMethod) == (IMP)WAGRLinkageWWWFetch;
    }
}

#pragma mark - Release no-op surfaces

static NSInteger WAGRLinkageApplyDebugOverrides(id userContext, NSString **outDiagnostic) {
    NSDictionary *source = WAGRLinkageMergedDebugOverrides(userContext);
    if (!source.count) {
        if (outDiagnostic) *outDiagnostic = @"No live/captured/tracked debug ABProps overrides to sync.";
        return 0;
    }

    __block NSInteger applied = 0;
    __block NSInteger skipped = 0;
    NSMutableSet<NSNumber *> *refreshIDs = [NSMutableSet set];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];

    [source enumerateKeysAndObjectsUsingBlock:^(id key, id rawValue, __unused BOOL *stop) {
        NSString *stableID = WAGRLinkageStableIDString(key);
        id scalar = WAGRLinkageOverrideScalar(rawValue);
        if (!stableID.length || !scalar) { skipped++; return; }

        NSString *mappingDiagnostic = nil;
        NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(stableID, userContext, &mappingDiagnostic);
        uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
        uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
        if (!mapping || !specifier || !externalID) {
            skipped++;
            if (failures.count < 12) [failures addObject:[NSString stringWithFormat:@"AB %@: %@", stableID, mappingDiagnostic ?: @"mapping failed"]];
            return;
        }

        if (WAGRLinkageStartupSet(specifier, scalar)) {
            applied++;
            [refreshIDs addObject:@(externalID)];
        } else {
            skipped++;
            if (failures.count < 12) [failures addObject:[NSString stringWithFormat:@"AB %@: StartupConfigs set failed", stableID]];
        }
    }];

    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = applied > 0 ? WAGRMobileConfigNativeInvalidate(userContext, &invalidateDiagnostic) : NO;
    NSUInteger refreshSent = 0;
    for (NSNumber *externalID in refreshIDs) {
        if (WAGRLinkageRefreshConfig(userContext, externalID.unsignedLongLongValue)) refreshSent++;
    }

    NSDictionary *readback = WAGRLinkageStartupReadback();
    WAGRLinkageRecord(@"sync_complete", @{
        @"source_count": @(source.count),
        @"applied": @(applied),
        @"skipped": @(skipped),
        @"native_invalidate": @(invalidated),
        @"targeted_refresh_requested": @(refreshSent),
        @"startup_readback": readback ?: @{},
        @"failures": failures
    });
    if (outDiagnostic) {
        *outDiagnostic = [NSString stringWithFormat:
            @"source=%lu applied=%ld skipped=%ld invalidate=%@ targetedRefresh=%lu startup=%@%@",
            (unsigned long)source.count, (long)applied, (long)skipped,
            invalidated ? @"YES" : @"NO", (unsigned long)refreshSent, readback,
            failures.count ? [@" failures=" stringByAppendingString:[failures componentsJoinedByString:@" | "]] : @""];
    }
    return applied;
}

static long long WAGRLinkageSyncSurface(id self, SEL _cmd, id userContext) {
    (void)self; (void)_cmd;
    id context = userContext ?: WAGRCurrentUserContext();
    NSString *diagnostic = nil;
    NSInteger applied = WAGRLinkageApplyDebugOverrides(context, &diagnostic);
    WAGRLogAppendF(@"[ABProps][ReleaseLinkage] syncABPropsOverridesToMC -> %@", diagnostic ?: @"no diagnostic");
    return (long long)applied;
}

static id WAGRLinkageStableIDsSurface(id self, SEL _cmd, id userContext) {
    (void)self; (void)_cmd;
    NSDictionary *source = WAGRLinkageMergedDebugOverrides(userContext ?: WAGRCurrentUserContext());
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    for (id key in source) {
        NSString *stable = WAGRLinkageStableIDString(key);
        if (stable.length) [ids addObject:@(stable.longLongValue)];
    }
    [ids sortUsingSelector:@selector(compare:)];
    return ids;
}

static void WAGRLinkageResetSurface(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    id context = WAGRCurrentUserContext();
    NSDictionary *source = WAGRLinkageMergedDebugOverrides(context);
    NSInteger removed = 0, skipped = 0;
    NSMutableSet<NSNumber *> *refreshIDs = [NSMutableSet set];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];

    for (id key in source) {
        NSString *stableID = WAGRLinkageStableIDString(key);
        if (!stableID.length) { skipped++; continue; }
        NSString *mappingDiagnostic = nil;
        NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(stableID, context, &mappingDiagnostic);
        uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
        uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
        if (!mapping || !specifier || !externalID) {
            skipped++;
            if (failures.count < 12) [failures addObject:[NSString stringWithFormat:@"AB %@: %@", stableID, mappingDiagnostic ?: @"mapping failed"]];
            continue;
        }
        if (WAGRLinkageStartupRemove(specifier)) {
            removed++;
            [refreshIDs addObject:@(externalID)];
        } else {
            skipped++;
            if (failures.count < 12) [failures addObject:[NSString stringWithFormat:@"AB %@: StartupConfigs remove failed", stableID]];
        }
    }

    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = removed > 0 ? WAGRMobileConfigNativeInvalidate(context, &invalidateDiagnostic) : NO;
    NSUInteger refreshSent = 0;
    for (NSNumber *externalID in refreshIDs) {
        if (WAGRLinkageRefreshConfig(context, externalID.unsignedLongLongValue)) refreshSent++;
    }

    WAGRLinkageRecord(@"reset_complete", @{
        @"identified_ab_overrides": @(source.count),
        @"removed": @(removed),
        @"skipped": @(skipped),
        @"native_invalidate": @(invalidated),
        @"targeted_refresh_requested": @(refreshSent),
        @"startup_readback": WAGRLinkageStartupReadback(),
        @"failures": failures
    });
    WAGRLogAppendF(@"[ABProps][ReleaseLinkage] resetAllOverriddenABProps identified=%lu removed=%ld skipped=%ld invalidate=%@ refresh=%lu",
                   (unsigned long)source.count, (long)removed, (long)skipped,
                   invalidated ? @"YES" : @"NO", (unsigned long)refreshSent);
}

static BOOL WAGRLinkageSyncSurfaceMayBeReplaced(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRLinkageReturnsInteger(method)) return NO;
    IMP imp = method_getImplementation(method);
    return WAGRLinkageIMPBelongsToTweak(imp) ||
           WAGRLinkageIsZeroReturnAddress(WAGRLinkageIMPAddress(imp), 0);
}

static BOOL WAGRLinkageResetSurfaceMayBeReplaced(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRLinkageReturnsVoid(method)) return NO;
    IMP imp = method_getImplementation(method);
    if (WAGRLinkageIMPBelongsToTweak(imp)) return YES;
    uintptr_t address = WAGRLinkageIMPAddress(imp);
    return address && WAGRLinkageIsRET(*(const uint32_t *)address);
}

static void WAGRLinkageInstallReleaseSurfaces(void) {
    Class syncClass = NSClassFromString(@"WAMobileConfigABPropsOverridesSync") ?:
                      objc_getClass("WAMobileConfigABPropsOverridesSync");
    if (syncClass) {
        Method sync = class_getClassMethod(syncClass, NSSelectorFromString(@"syncABPropsOverridesToMCWithUserContext:"));
        if (!gWAGRSyncLinked && WAGRLinkageSyncSurfaceMayBeReplaced(sync)) {
            method_setImplementation(sync, (IMP)WAGRLinkageSyncSurface);
            gWAGRSyncLinked = method_getImplementation(sync) == (IMP)WAGRLinkageSyncSurface;
        }

        Method ids = class_getClassMethod(syncClass, NSSelectorFromString(@"overriddenStableIdsWithUserContext:"));
        if (!gWAGRIDsLinked && ids && method_getNumberOfArguments(ids) == 3 && WAGRLinkageReturnsObject(ids) &&
            (gWAGRSyncLinked || WAGRLinkageIMPBelongsToTweak(method_getImplementation(ids)))) {
            method_setImplementation(ids, (IMP)WAGRLinkageStableIDsSurface);
            gWAGRIDsLinked = method_getImplementation(ids) == (IMP)WAGRLinkageStableIDsSurface;
        }
    }

    Class debug = NSClassFromString(@"WADebugViewController") ?: objc_getClass("WADebugViewController");
    Method reset = debug ? class_getInstanceMethod(debug, NSSelectorFromString(@"resetAllOverriddenABProps")) : NULL;
    if (!gWAGRResetLinked && WAGRLinkageResetSurfaceMayBeReplaced(reset)) {
        method_setImplementation(reset, (IMP)WAGRLinkageResetSurface);
        gWAGRResetLinked = method_getImplementation(reset) == (IMP)WAGRLinkageResetSurface;
    }

    if (gWAGRSyncLinked || gWAGRIDsLinked || gWAGRResetLinked) {
        WAGRLinkageRecord(@"release_surfaces_linked", @{
            @"sync": @(gWAGRSyncLinked),
            @"overridden_ids": @(gWAGRIDsLinked),
            @"reset": @(gWAGRResetLinked)
        });
    }
}

static void WAGRLinkageInstallInitializerObservers(void) {
    Class wa = NSClassFromString(@"WAProperties") ?: objc_getClass("WAProperties");
    if (!gWAGRWAPropertiesInitHooked && wa) {
        gWAGRWAPropertiesInitHooked = WAGRLinkageInstallInitializerObserverForClass(
            wa, (IMP)WAGRLinkageWAPropertiesInit, (IMP *)&gWAGRWAPropertiesInitOriginal);
    }

    Class ab = NSClassFromString(@"WAABProperties") ?: objc_getClass("WAABProperties");
    if (!gWAGRWAABPropertiesInitHooked && ab) {
        Method own = class_getInstanceMethod(ab, NSSelectorFromString(@"initWithPropertiesStore:debugOverrides:"));
        Method base = wa ? class_getInstanceMethod(wa, NSSelectorFromString(@"initWithPropertiesStore:debugOverrides:")) : NULL;
        if (own && (!base || method_getImplementation(own) != method_getImplementation(base))) {
            gWAGRWAABPropertiesInitHooked = WAGRLinkageInstallInitializerObserverForClass(
                ab, (IMP)WAGRLinkageWAABPropertiesInit, (IMP *)&gWAGRWAABPropertiesInitOriginal);
        }
    }
}

NSDictionary<NSString *, id> *WAGRABPropsReleaseNativeLinkageDiagnosticDocument(void) {
    WAGRLinkageEnsureState();
    NSArray *events = nil;
    NSDictionary *captured = nil;
    @synchronized (gWAGRLinkageLock) {
        events = [gWAGRLinkageEvents copy] ?: @[];
        captured = [gWAGRLastCapturedDebugOverrides copy] ?: @{};
    }

    id context = WAGRCurrentUserContext();
    id manager = WAGRMobileConfigUserSessionContextManager(context);
    Method refresh = manager ? class_getInstanceMethod([manager class], NSSelectorFromString(@"forceRefreshOfConfig:")) : NULL;
    Method setOverrides = manager ? class_getInstanceMethod([manager class], NSSelectorFromString(@"setOverrides:")) : NULL;
    NSString *setOverridesEncoding = WAGRLinkageEncoding(setOverrides);

    return @{
        @"release_surfaces": @{
            @"sync_linked": @(gWAGRSyncLinked),
            @"overridden_ids_linked": @(gWAGRIDsLinked),
            @"reset_linked": @(gWAGRResetLinked)
        },
        @"debug_override_bridge": @{
            @"wa_properties_initializer_observed": @(gWAGRWAPropertiesInitHooked),
            @"waab_properties_initializer_observed": @(gWAGRWAABPropertiesInitHooked),
            @"captured_nonempty_count": @(captured.count),
            @"merged_effective_count": @(WAGRLinkageMergedDebugOverrides(context).count)
        },
        @"startup_configs": WAGRLinkageStartupReadback(),
        @"mobileconfig_manager": @{
            @"resolved": @(manager != nil),
            @"class": manager ? (NSStringFromClass([manager class]) ?: @"?") : @"nil",
            @"force_refresh_encoding": WAGRLinkageEncoding(refresh),
            @"set_overrides_encoding": setOverridesEncoding ?: @"",
            @"set_overrides_is_cpp_shared_ptr": @([setOverridesEncoding containsString:@"shared_ptr"] || [setOverridesEncoding containsString:@"FBMobileConfigOverridesTable"])
        },
        @"network_observers": @{
            @"xwa2_installed": @(gWAGRXWA2ObserverHooked),
            @"www_installed": @(gWAGRWWWObserverHooked)
        },
        @"events": events,
        @"policy": @"Release no-ops are linked to WAMCEvaluation + FBMobileConfigStartupConfigs + UserSession invalidation/targeted refresh. XWA2/WWW are observed to prove the native fetch backend. No synthetic WAMobileConfigFetchInput is created; setOverrides:(shared_ptr) is never objc_msgSend'd; this linkage does not claim or implement the unresolved main FBMobileConfigOverridesTable serializer."
    };
}

__attribute__((constructor))
static void WAGRABPropsReleaseNativeLinkageCtor(void) {
    @autoreleasepool {
        WAGRLinkageEnsureState();
        // Named classes/selectors only. No Objective-C class enumeration and no
        // Mach-O scan on the cold-start critical path.
        for (NSNumber *delay in @[@0.50, @1.25, @2.50, @4.00]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRLinkageInstallInitializerObservers();
                WAGRLinkageInstallFetchObservers();
                WAGRLinkageInstallReleaseSurfaces();
            });
        }
    }
}
