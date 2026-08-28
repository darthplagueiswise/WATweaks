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
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

// Release-build compatibility for the ABProps -> MobileConfig debug surfaces.
//
// The supplied WhatsApp/SharedModules build proves these responsibilities are
// now split across live components:
//   AB stable ID -> WAMCEvaluation -> MC paramSpecifier
//   paramSpecifier -> FBMobileConfigStartupConfigs typed override writer
//   FBMobileConfigUserSessionContextManager -> targeted refresh/update
//   WAMobileConfigGraphQLFetcher -> MobileConfigFetchQuery -> XWA2
//
// This file reconnects only the release surfaces that are demonstrably disabled.
// It does NOT call FBMobileConfigContextManager.setOverrides: because that method
// takes std::shared_ptr<FBMobileConfigOverridesTable>, not an Objective-C object.
// It also does NOT fabricate a WAMobileConfigFetchInput: targeted refresh is
// delegated to the live account-scoped manager and the real GraphQL fetcher is
// observed to prove which backend the manager selected.

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
static BOOL gWAGRReleaseSurfacesLinked = NO;

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
        if (gWAGRLinkageEvents.count > 96) {
            [gWAGRLinkageEvents removeObjectsInRange:NSMakeRange(0, gWAGRLinkageEvents.count - 96)];
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

static BOOL WAGRLinkageArgUInt32(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    char type = WAGRLinkageSkipQualifiers(raw)[0];
    return type == 'I' || type == 'i';
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
    if (!address || depth > 2) return NO;
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

static void WAGRLinkageCaptureDebugOverrides(id owner, id debugOverrides, NSString *source) {
    if (![debugOverrides isKindOfClass:NSDictionary.class] || [(NSDictionary *)debugOverrides count] == 0) return;
    objc_setAssociatedObject(owner, kWAGRDebugOverridesAssociationKey,
                             debugOverrides, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    WAGRLinkageCaptureDebugOverrides(result ?: self, debugOverrides, @"WAProperties.initWithPropertiesStore:debugOverrides:");
    return result;
}

static id WAGRLinkageWAABPropertiesInit(id self, SEL _cmd, id store, id debugOverrides) {
    id result = gWAGRWAABPropertiesInitOriginal ? gWAGRWAABPropertiesInitOriginal(self, _cmd, store, debugOverrides) : self;
    WAGRLinkageCaptureDebugOverrides(result ?: self, debugOverrides, @"WAABProperties.initWithPropertiesStore:debugOverrides:");
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

static NSDictionary *WAGRLinkageDebugOverrides(id userContext) {
    id direct = WAGRLinkageObjectNoArg(userContext, @"debugPropOverrides");
    if ([direct isKindOfClass:NSDictionary.class] && [(NSDictionary *)direct count]) return direct;

    for (NSString *accessor in @[@"abProperties", @"privateABProperties", @"waABProperties", @"properties"]) {
        id properties = WAGRLinkageObjectNoArg(userContext, accessor);
        id associated = properties ? objc_getAssociatedObject(properties, kWAGRDebugOverridesAssociationKey) : nil;
        if ([associated isKindOfClass:NSDictionary.class] && [(NSDictionary *)associated count]) return associated;
    }

    @synchronized (gWAGRLinkageLock) {
        if (gWAGRLastCapturedDebugOverrides.count) return gWAGRLastCapturedDebugOverrides;
    }
    NSDictionary *tracked = WAGRABPropsNativeTrackedOverrides();
    return tracked.count ? tracked : @{};
}

static NSUInteger WAGRLinkageStableIDFromKey(id key) {
    if ([key isKindOfClass:NSNumber.class]) return [key unsignedIntegerValue];
    if (![key isKindOfClass:NSString.class]) return 0;
    NSString *string = [(NSString *)key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!string.length) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:string];
    unsigned long long value = 0;
    if ([scanner scanUnsignedLongLong:&value] && scanner.isAtEnd) return (NSUInteger)value;
    return 0;
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
    // WAPBConfigOverrideValue is a GPBMessage in this build. Its generated
    // fields are not exported as ObjC methods in the runtime snapshot, so only
    // use KVC when an actual scalar field exists; never reinterpret its bytes.
    for (NSString *key in @[@"value", @"boolValue", @"int64Value", @"integerValue", @"doubleValue", @"stringValue"]) {
        @try {
            id candidate = [value valueForKey:key];
            if ([candidate isKindOfClass:NSNumber.class] || [candidate isKindOfClass:NSString.class]) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

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
        !WAGRLinkageArgObject(method, 3)) return NO;
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
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRLinkageReturnsVoid(method)) return NO;
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
    if (!startup) return @{};
    id overrides = WAGRLinkageObjectNoArg(startup, @"configValuesOverride");
    id json = WAGRLinkageObjectNoArg(startup, @"toJSON");
    return @{
        @"class": NSStringFromClass([startup class]) ?: @"?",
        @"configValuesOverride_class": overrides ? (NSStringFromClass([overrides class]) ?: @"?") : @"nil",
        @"configValuesOverride_count": [overrides respondsToSelector:@selector(count)] ? @([overrides count]) : @0,
        @"toJSON_class": json ? (NSStringFromClass([json class]) ?: @"?") : @"nil",
        @"toJSON_length": [json respondsToSelector:@selector(length)] ? @([json length]) : @0,
    };
}

static BOOL WAGRLinkageRefreshConfig(id userContext, uint64_t externalStableID) {
    if (!externalStableID || externalStableID > UINT32_MAX) return NO;
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    SEL selector = NSSelectorFromString(@"forceRefreshOfConfig:");
    Method method = manager ? class_getInstanceMethod([manager class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRLinkageReturnsVoid(method) ||
        !WAGRLinkageArgUInt32(method, 2)) return NO;
    @try {
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(manager, selector, (uint32_t)externalStableID);
        WAGRLinkageRecord(@"manager_force_refresh", @{
            @"manager": NSStringFromClass([manager class]) ?: @"?",
            @"external_config_stable_id": @(externalStableID)
        });
        return YES;
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] forceRefreshOfConfig:%llu threw %@",
                       externalStableID, exception.reason ?: @"exception");
        return NO;
    }
}

static NSDictionary *WAGRLinkageXWA2InputSnapshot(id input) {
    if (!input) return @{};
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithObject:(NSStringFromClass([input class]) ?: @"?") forKey:@"input_class"];
    for (NSString *selector in @[@"unitType", @"apiVersion", @"fetchType", @"globalValueHash", @"epRefreshId",
                                 @"unitId", @"queryString", @"batchSize", @"blnLiHashes", @"blnQueries", @"boolOptPolicy"]) {
        id value = WAGRLinkageScalarOrObjectNoArg(input, selector);
        if (value) snapshot[selector] = [value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] ? value : ([value description] ?: @"?");
    }
    return snapshot;
}

static void WAGRLinkageXWA2Fetch(id self, SEL _cmd, id input, id completion) {
    NSDictionary *snapshot = WAGRLinkageXWA2InputSnapshot(input);
    WAGRLinkageRecord(@"xwa2_fetch_entered", snapshot);
    WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] native XWA2 fetch entered %@", snapshot);
    if (gWAGRXWA2FetchOriginal) gWAGRXWA2FetchOriginal(self, _cmd, input, completion);
}

static void WAGRLinkageWWWFetch(id self, SEL _cmd, id input, BOOL sessionless, id completion) {
    WAGRLinkageRecord(@"www_fetch_entered", @{
        @"input_class": input ? (NSStringFromClass([input class]) ?: @"?") : @"nil",
        @"sessionless": @(sessionless)
    });
    WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] native WWW fetch entered sessionless=%@ input=%@",
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

static NSSet<NSString *> *WAGRLinkagePhysicalOverridePairs(id userContext) {
    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data.length) return [NSSet set];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return [NSSet set];

    NSMutableSet<NSString *> *pairs = [NSMutableSet set];
    [(NSDictionary *)json enumerateKeysAndObjectsUsingBlock:^(id key, id rows, __unused BOOL *stop) {
        NSString *keyString = [key description] ?: @"";
        NSString *stablePart = [[keyString componentsSeparatedByString:@":"] firstObject] ?: @"";
        unsigned long long externalID = strtoull(stablePart.UTF8String, NULL, 10);
        if (!externalID || ![rows isKindOfClass:NSArray.class]) return;
        for (id row in (NSArray *)rows) {
            if (![row isKindOfClass:NSString.class]) continue;
            NSString *paramPart = [[(NSString *)row componentsSeparatedByString:@":"] firstObject] ?: @"";
            unsigned long long parameterIndex = strtoull(paramPart.UTF8String, NULL, 10);
            [pairs addObject:[NSString stringWithFormat:@"%llu:%llu", externalID, parameterIndex]];
        }
    }];
    return pairs;
}

static NSArray<NSNumber *> *WAGRLinkageActiveABStableIDs(id userContext) {
    NSMutableSet<NSNumber *> *result = [NSMutableSet setWithArray:WAGRABPropsNativeTrackedStableIDs() ?: @[]];
    NSSet<NSString *> *pairs = WAGRLinkagePhysicalOverridePairs(userContext);
    if (!pairs.count) return [[result allObjects] sortedArrayUsingSelector:@selector(compare:)];

    NSError *error = nil;
    NSArray<WAGRMobileConfigMapping *> *all = WAGRMobileConfigResolveAll(userContext, nil, &error);
    if (!all.count) {
        WAGRLogAppendF(@"[ABProps][ReleaseLinkage] active-ID crosswalk unavailable: %@", error.localizedDescription ?: @"unknown");
        return [[result allObjects] sortedArrayUsingSelector:@selector(compare:)];
    }
    for (WAGRMobileConfigMapping *mapping in all) {
        if (!mapping.waStableId || !mapping.configStableId) continue;
        NSString *pair = [NSString stringWithFormat:@"%llu:%u",
                          mapping.configStableId, mapping.parameterIndex];
        if ([pairs containsObject:pair]) [result addObject:@(mapping.waStableId)];
    }
    return [[result allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

static NSInteger WAGRLinkageApplyDebugOverrides(id userContext, NSString **outDiagnostic) {
    NSDictionary *source = WAGRLinkageDebugOverrides(userContext);
    if (!source.count) {
        if (outDiagnostic) *outDiagnostic = @"No live/captured debug ABProps overrides to sync.";
        return 0;
    }

    NSInteger applied = 0, skipped = 0;
    NSMutableSet<NSNumber *> *refreshIDs = [NSMutableSet set];
    [source enumerateKeysAndObjectsUsingBlock:^(id key, id rawValue, __unused BOOL *stop) {
        NSUInteger stableID = WAGRLinkageStableIDFromKey(key);
        id scalar = WAGRLinkageOverrideScalar(rawValue);
        if (!stableID || !scalar) { skipped++; return; }

        NSError *mappingError = nil;
        NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(stableID, userContext, &mappingError);
        uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
        uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
        if (!specifier || !externalID) { skipped++; return; }

        if (WAGRLinkageStartupSet(specifier, scalar)) {
            applied++;
            [refreshIDs addObject:@(externalID)];
        } else {
            skipped++;
        }
    }];

    for (NSNumber *externalID in refreshIDs) {
        (void)WAGRLinkageRefreshConfig(userContext, externalID.unsignedLongLongValue);
    }

    NSDictionary *readback = WAGRLinkageStartupReadback();
    WAGRLinkageRecord(@"sync_complete", @{
        @"source_count": @(source.count), @"applied": @(applied), @"skipped": @(skipped),
        @"refresh_config_count": @(refreshIDs.count), @"startup_readback": readback ?: @{}
    });
    if (outDiagnostic) {
        *outDiagnostic = [NSString stringWithFormat:@"source=%lu applied=%ld skipped=%ld refreshConfigs=%lu startup=%@",
                          (unsigned long)source.count, (long)applied, (long)skipped,
                          (unsigned long)refreshIDs.count, readback];
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
    return WAGRLinkageActiveABStableIDs(userContext ?: WAGRCurrentUserContext());
}

static void WAGRLinkageResetSurface(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    id context = WAGRCurrentUserContext();
    NSArray<NSNumber *> *stableIDs = WAGRLinkageActiveABStableIDs(context);
    NSInteger removed = 0, skipped = 0;
    NSMutableSet<NSNumber *> *refreshIDs = [NSMutableSet set];
    for (NSNumber *stableNumber in stableIDs) {
        NSError *error = nil;
        NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(stableNumber.unsignedIntegerValue, context, &error);
        uint64_t specifier = [mapping[@"param_specifier"] unsignedLongLongValue];
        uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
        if (!specifier || !externalID) { skipped++; continue; }
        if (WAGRLinkageStartupRemove(specifier)) {
            removed++;
            [refreshIDs addObject:@(externalID)];
        } else {
            skipped++;
        }
    }
    for (NSNumber *externalID in refreshIDs) {
        (void)WAGRLinkageRefreshConfig(context, externalID.unsignedLongLongValue);
    }
    WAGRLinkageRecord(@"reset_complete", @{
        @"identified_ab_overrides": @(stableIDs.count), @"removed": @(removed),
        @"skipped": @(skipped), @"refresh_config_count": @(refreshIDs.count),
        @"startup_readback": WAGRLinkageStartupReadback()
    });
    WAGRLogAppendF(@"[ABProps][ReleaseLinkage] resetAllOverriddenABProps identified=%lu removed=%ld skipped=%ld",
                   (unsigned long)stableIDs.count, (long)removed, (long)skipped);
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
    BOOL syncLinked = NO, idsLinked = NO, resetLinked = NO;
    if (syncClass) {
        Method sync = class_getClassMethod(syncClass, NSSelectorFromString(@"syncABPropsOverridesToMCWithUserContext:"));
        if (WAGRLinkageSyncSurfaceMayBeReplaced(sync)) {
            method_setImplementation(sync, (IMP)WAGRLinkageSyncSurface);
            syncLinked = method_getImplementation(sync) == (IMP)WAGRLinkageSyncSurface;
        }

        Method ids = class_getClassMethod(syncClass, NSSelectorFromString(@"overriddenStableIdsWithUserContext:"));
        if (ids && method_getNumberOfArguments(ids) == 3 && WAGRLinkageReturnsObject(ids) &&
            (syncLinked || WAGRLinkageIMPBelongsToTweak(method_getImplementation(ids)))) {
            method_setImplementation(ids, (IMP)WAGRLinkageStableIDsSurface);
            idsLinked = method_getImplementation(ids) == (IMP)WAGRLinkageStableIDsSurface;
        }
    }

    Class debug = NSClassFromString(@"WADebugViewController") ?: objc_getClass("WADebugViewController");
    Method reset = debug ? class_getInstanceMethod(debug, NSSelectorFromString(@"resetAllOverriddenABProps")) : NULL;
    if (WAGRLinkageResetSurfaceMayBeReplaced(reset)) {
        method_setImplementation(reset, (IMP)WAGRLinkageResetSurface);
        resetLinked = method_getImplementation(reset) == (IMP)WAGRLinkageResetSurface;
    }

    gWAGRReleaseSurfacesLinked = syncLinked || idsLinked || resetLinked;
    if (gWAGRReleaseSurfacesLinked) {
        WAGRLinkageRecord(@"release_surfaces_linked", @{
            @"sync": @(syncLinked), @"overridden_ids": @(idsLinked), @"reset": @(resetLinked)
        });
        WAGRLogAppendF(@"[ABProps][ReleaseLinkage] linked sync=%@ ids=%@ reset=%@",
                       syncLinked ? @"YES" : @"NO", idsLinked ? @"YES" : @"NO", resetLinked ? @"YES" : @"NO");
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
        // Hook the subclass only when it owns a distinct implementation. If it
        // simply inherits WAProperties, the base observer already captures x3.
        if (own && (!base || method_getImplementation(own) != method_getImplementation(base))) {
            gWAGRWAABPropertiesInitHooked = WAGRLinkageInstallInitializerObserverForClass(
                ab, (IMP)WAGRLinkageWAABPropertiesInit, (IMP *)&gWAGRWAABPropertiesInitOriginal);
        }
    }
}

NSDictionary<NSString *, id> *WAGRABPropsReleaseNativeLinkageDiagnosticDocument(void) {
    WAGRLinkageEnsureState();
    NSArray *events = nil;
    @synchronized (gWAGRLinkageLock) { events = [gWAGRLinkageEvents copy] ?: @[]; }
    return @{
        @"release_surfaces_linked": @(gWAGRReleaseSurfacesLinked),
        @"wa_properties_debug_initializer_observed": @(gWAGRWAPropertiesInitHooked),
        @"waab_properties_debug_initializer_observed": @(gWAGRWAABPropertiesInitHooked),
        @"xwa2_fetch_observer_installed": @(gWAGRXWA2ObserverHooked),
        @"www_fetch_observer_installed": @(gWAGRWWWObserverHooked),
        @"captured_debug_override_count": @(gWAGRLastCapturedDebugOverrides.count),
        @"events": events,
        @"policy": @"Disabled release ABProps surfaces are connected to WAMCEvaluation + FBMobileConfigStartupConfigs + account-scoped forceRefreshOfConfig:. XWA2/WWW native fetchers are observed. setOverrides:(shared_ptr) is never objc_msgSend'd and no synthetic WAMobileConfigFetchInput is fabricated."
    };
}

__attribute__((constructor))
static void WAGRABPropsReleaseNativeLinkageCtor(void) {
    @autoreleasepool {
        WAGRLinkageEnsureState();
        // Named-method work only; no class catalog scan at cold start.
        for (NSNumber *delay in @[@0.75, @1.75, @3.50]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRLinkageInstallInitializerObservers();
                WAGRLinkageInstallFetchObservers();
                WAGRLinkageInstallReleaseSurfaces();
            });
        }
    }
}
