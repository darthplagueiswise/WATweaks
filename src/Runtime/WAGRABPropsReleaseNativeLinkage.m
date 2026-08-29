#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#import "WAGRABPropsNativeOverrideEngine.h"
#import "WAGRABPropsStableIDResolver.h"
#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

// WhatsApp 26.33 release scaffolds are reconnected to ONE verified local writer:
//
//   AB stable ID -> WAMCEvaluation -> typed FBMobileConfigStartupConfigs writer
//   -> native METAAppGroup(app) defaults readback -> context invalidation
//   -> account-scoped typed effective getter readback.
//
// Server fetch is intentionally separate. The XWA2/WWW hooks in this file are
// passive observers used by WAGRMobileConfigNativeFetchAccount; they never
// synthesize WAMobileConfigFetchInput, GraphQL, hashes or access tokens.

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
        if (gWAGRLinkageEvents.count > 192) {
            [gWAGRLinkageEvents removeObjectsInRange:NSMakeRange(0, gWAGRLinkageEvents.count - 192)];
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
    char raw[64] = {0}; method_getReturnType(method, raw, sizeof(raw));
    return WAGRLinkageSkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRLinkageReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0}; method_getReturnType(method, raw, sizeof(raw));
    return WAGRLinkageSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRLinkageReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[64] = {0}; method_getReturnType(method, raw, sizeof(raw));
    return strchr("cCsSiIlLqQB", WAGRLinkageSkipQualifiers(raw)[0]) != NULL;
}

static BOOL WAGRLinkageArgObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0}; method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRLinkageSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRLinkageArgBool(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0}; method_getArgumentType(method, index, raw, sizeof(raw));
    char type = WAGRLinkageSkipQualifiers(raw)[0];
    return type == 'B' || type == 'c' || type == 'C';
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

static BOOL WAGRLinkageIsRET(uint32_t instruction) { return instruction == 0xD65F03C0u; }
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
    char raw[64] = {0}; method_getReturnType(method, raw, sizeof(raw));
    if (WAGRLinkageSkipQualifiers(raw)[0] == 'd') {
        @try { return @(((double (*)(id, SEL))objc_msgSend)(target, selector)); }
        @catch (__unused NSException *exception) { return nil; }
    }
    return nil;
}

#pragma mark - Capture release initializer debugOverrides

static void WAGRLinkageCaptureDebugOverrides(id owner, id debugOverrides, NSString *source) {
    WAGRLinkageEnsureState();
    if (![debugOverrides isKindOfClass:NSDictionary.class] || [(NSDictionary *)debugOverrides count] == 0) return;
    if (owner) objc_setAssociatedObject(owner, kWAGRDebugOverridesAssociationKey,
                                        debugOverrides, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized (gWAGRLinkageLock) { gWAGRLastCapturedDebugOverrides = [debugOverrides copy]; }
    WAGRLinkageRecord(@"debug_overrides_captured", @{
        @"source" : source ?: @"initializer",
        @"count" : @([(NSDictionary *)debugOverrides count]),
        @"owner" : owner ? (NSStringFromClass([owner class]) ?: @"?") : @"nil"
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

static NSDictionary *WAGRLinkageMergedDebugOverrides(id userContext) {
    WAGRLinkageEnsureState();
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSDictionary *tracked = WAGRABPropsNativeTrackedOverrides();
    if ([tracked isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:tracked];
    NSDictionary *captured = nil;
    @synchronized (gWAGRLinkageLock) { captured = [gWAGRLastCapturedDebugOverrides copy]; }
    if (captured.count) [merged addEntriesFromDictionary:captured];
    for (NSString *accessor in @[@"abProperties", @"privateABProperties", @"waABProperties", @"properties"]) {
        id owner = WAGRLinkageObjectNoArg(userContext, accessor);
        id associated = owner ? objc_getAssociatedObject(owner, kWAGRDebugOverridesAssociationKey) : nil;
        if ([associated isKindOfClass:NSDictionary.class] && [(NSDictionary *)associated count]) [merged addEntriesFromDictionary:associated];
    }
    id direct = WAGRLinkageObjectNoArg(userContext, @"debugPropOverrides");
    if ([direct isKindOfClass:NSDictionary.class] && [(NSDictionary *)direct count]) [merged addEntriesFromDictionary:direct];
    return [merged copy];
}

static void WAGRLinkageClearCapturedDebugState(id userContext) {
    WAGRLinkageEnsureState();
    @synchronized (gWAGRLinkageLock) { gWAGRLastCapturedDebugOverrides = @{}; }
    for (NSString *accessor in @[@"abProperties", @"privateABProperties", @"waABProperties", @"properties"]) {
        id owner = WAGRLinkageObjectNoArg(userContext, accessor);
        if (owner) objc_setAssociatedObject(owner, kWAGRDebugOverridesAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id direct = WAGRLinkageObjectNoArg(userContext, @"debugPropOverrides");
    if ([direct isKindOfClass:NSMutableDictionary.class]) [(NSMutableDictionary *)direct removeAllObjects];
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
    if (bytes && *bytes) {
        char *end = NULL;
        unsigned long long value = strtoull(bytes, &end, 10);
        if (value && end != bytes && end && *end == '\0') return [NSString stringWithFormat:@"%llu", value];
    }
    if ([string rangeOfString:@":"].location == NSNotFound) {
        for (NSString *className in @[@"WAABProperties", @"WAPrivateExperimentation.PrivateABProperties", @"WAGroupABProperties"]) {
            Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
            Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(string)) : NULL;
            if (!method || method_getNumberOfArguments(method) != 2) continue;
            NSString *resolved = WAGRABPropsStableIDForTarget(className, string, NO);
            if (resolved.length) return resolved;
        }
    }
    return nil;
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
    for (NSString *key in @[@"value", @"boolValue", @"int64Value", @"integerValue", @"doubleValue", @"stringValue"]) {
        @try {
            id candidate = [value valueForKey:key];
            if ([candidate isKindOfClass:NSNumber.class] || [candidate isKindOfClass:NSString.class]) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

#pragma mark - Native network observers

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
    WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] XWA2 fetch observed %@", snapshot);
    if (gWAGRXWA2FetchOriginal) gWAGRXWA2FetchOriginal(self, _cmd, input, completion);
}

static void WAGRLinkageWWWFetch(id self, SEL _cmd, id input, BOOL sessionless, id completion) {
    NSMutableDictionary *snapshot = [WAGRLinkageXWA2InputSnapshot(input) mutableCopy];
    if (!snapshot) snapshot = [NSMutableDictionary dictionary];
    snapshot[@"sessionless"] = @(sessionless);
    WAGRLinkageRecord(@"www_native_fetch_observed", snapshot);
    WAGRLogAppendF(@"[MobileConfig][ReleaseLinkage] WWW fetch observed %@", snapshot);
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

#pragma mark - Release no-op surfaces -> unified verified writer

static NSInteger WAGRLinkageApplyDebugOverrides(id userContext, NSString **outDiagnostic) {
    NSDictionary *source = WAGRLinkageMergedDebugOverrides(userContext);
    if (!source.count) {
        if (outDiagnostic) *outDiagnostic = @"No live/captured/tracked debug ABProps overrides to sync.";
        return 0;
    }
    __block NSInteger applied = 0, skipped = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    [source enumerateKeysAndObjectsUsingBlock:^(id key, id rawValue, __unused BOOL *stop) {
        NSString *stableID = WAGRLinkageStableIDString(key);
        id scalar = WAGRLinkageOverrideScalar(rawValue);
        if (!stableID.length || !scalar) { skipped++; return; }
        NSError *error = nil;
        NSString *diagnostic = nil;
        if (WAGRABPropsNativeSetOverride(stableID, scalar, userContext, &error, &diagnostic)) {
            applied++;
        } else {
            skipped++;
            if (failures.count < 12) [failures addObject:[NSString stringWithFormat:@"AB %@: %@", stableID, error.localizedDescription ?: diagnostic ?: @"failed"]];
        }
    }];
    WAGRLinkageRecord(@"sync_complete", @{
        @"source_count" : @(source.count), @"applied" : @(applied), @"skipped" : @(skipped), @"failures" : failures,
        @"writer" : @"WAGRABPropsNativeSetOverride verified pipeline"
    });
    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"source=%lu applied=%ld skipped=%ld%@",
        (unsigned long)source.count, (long)applied, (long)skipped,
        failures.count ? [@" failures=" stringByAppendingString:[failures componentsJoinedByString:@" | "]] : @""];
    return applied;
}

static long long WAGRLinkageSyncSurface(id self, SEL _cmd, id userContext) {
    (void)self; (void)_cmd;
    NSString *diagnostic = nil;
    NSInteger applied = WAGRLinkageApplyDebugOverrides(userContext ?: WAGRCurrentUserContext(), &diagnostic);
    WAGRLogAppendF(@"[ABProps][ReleaseLinkage] syncABPropsOverridesToMC -> %@", diagnostic ?: @"no diagnostic");
    return (long long)applied;
}

static id WAGRLinkageStableIDsSurface(id self, SEL _cmd, id userContext) {
    (void)self; (void)_cmd;
    NSDictionary *source = WAGRLinkageMergedDebugOverrides(userContext ?: WAGRCurrentUserContext());
    NSMutableSet<NSNumber *> *unique = [NSMutableSet set];
    for (id key in source) {
        NSString *stable = WAGRLinkageStableIDString(key);
        if (stable.length) [unique addObject:@(stable.longLongValue)];
    }
    NSMutableArray<NSNumber *> *ids = [[unique allObjects] mutableCopy];
    [ids sortUsingSelector:@selector(compare:)];
    return ids;
}

static void WAGRLinkageResetSurface(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    id context = WAGRCurrentUserContext();
    NSDictionary *source = WAGRLinkageMergedDebugOverrides(context);
    NSInteger removed = 0, skipped = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (id key in source) {
        NSString *stableID = WAGRLinkageStableIDString(key);
        if (!stableID.length) { skipped++; continue; }
        NSError *error = nil;
        NSString *diagnostic = nil;
        if (WAGRABPropsNativeClearOverride(stableID, context, &error, &diagnostic)) removed++;
        else {
            skipped++;
            if (failures.count < 12) [failures addObject:[NSString stringWithFormat:@"AB %@: %@", stableID, error.localizedDescription ?: diagnostic ?: @"failed"]];
        }
    }
    WAGRLinkageClearCapturedDebugState(context);
    WAGRLinkageRecord(@"reset_complete", @{
        @"identified_ab_overrides" : @(source.count), @"removed" : @(removed), @"skipped" : @(skipped), @"failures" : failures,
        @"writer" : @"WAGRABPropsNativeClearOverride verified pipeline"
    });
    WAGRLogAppendF(@"[ABProps][ReleaseLinkage] reset identified=%lu removed=%ld skipped=%ld",
                   (unsigned long)source.count, (long)removed, (long)skipped);
}

static BOOL WAGRLinkageSyncSurfaceMayBeReplaced(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRLinkageReturnsInteger(method)) return NO;
    IMP imp = method_getImplementation(method);
    return WAGRLinkageIMPBelongsToTweak(imp) || WAGRLinkageIsZeroReturnAddress(WAGRLinkageIMPAddress(imp), 0);
}

static BOOL WAGRLinkageResetSurfaceMayBeReplaced(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRLinkageReturnsVoid(method)) return NO;
    IMP imp = method_getImplementation(method);
    if (WAGRLinkageIMPBelongsToTweak(imp)) return YES;
    uintptr_t address = WAGRLinkageIMPAddress(imp);
    return address && WAGRLinkageIsRET(*(const uint32_t *)address);
}

static void WAGRLinkageInstallReleaseSurfaces(void) {
    Class syncClass = NSClassFromString(@"WAMobileConfigABPropsOverridesSync") ?: objc_getClass("WAMobileConfigABPropsOverridesSync");
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

static void WAGRLinkageInstallAll(void) {
    WAGRLinkageInstallInitializerObservers();
    WAGRLinkageInstallFetchObservers();
    WAGRLinkageInstallReleaseSurfaces();
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
    return @{
        @"release_surfaces" : @{
            @"sync_linked" : @(gWAGRSyncLinked), @"overridden_ids_linked" : @(gWAGRIDsLinked), @"reset_linked" : @(gWAGRResetLinked)
        },
        @"debug_override_bridge" : @{
            @"wa_properties_initializer_observed" : @(gWAGRWAPropertiesInitHooked),
            @"waab_properties_initializer_observed" : @(gWAGRWAABPropertiesInitHooked),
            @"captured_nonempty_count" : @(captured.count),
            @"merged_effective_count" : @(WAGRLinkageMergedDebugOverrides(context).count),
            @"tracked_count" : @(WAGRABPropsNativeTrackedOverrides().count)
        },
        @"startup_configs" : WAGRABPropsNativeStartupOverrideStoreDocument(),
        @"mobileconfig_native_engine" : WAGRMobileConfigNativeEngineDiagnosticDocument(context),
        @"network_observers" : @{
            @"xwa2_installed" : @(gWAGRXWA2ObserverHooked), @"www_installed" : @(gWAGRWWWObserverHooked)
        },
        @"events" : events,
        @"policy" : @"Release ABProps no-op surfaces use the same verified StartupConfigs/AppGroup/effective-readback writer as the runtime browser. Server MobileConfig fetch is a separate WAChatManager pipeline. No direct mc_overrides.json writes and no objc_msgSend of setOverrides:(shared_ptr)."
    };
}

__attribute__((constructor))
static void WAGRABPropsReleaseNativeLinkageCtor(void) {
    @autoreleasepool {
        WAGRLinkageEnsureState();
        WAGRLinkageInstallAll();
        for (NSNumber *delay in @[@0.25, @0.75, @1.50, @3.00]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRLinkageInstallAll();
            });
        }
    }
}
