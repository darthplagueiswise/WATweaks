#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRMobileConfigFetchPolicy.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

extern id WAGRCurrentUserContext(void);
extern NSDictionary<NSString *, id> *WAGRABPropsReleaseNativeLinkageDiagnosticDocument(void);

static NSString * const kWAGRMCNativeErrorDomain = @"WATweaks.MobileConfigNativeEngine";

static const char *WAGRMCNativeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCNativeMethodReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCNativeSkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRMCNativeMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCNativeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCNativeArgBool(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    char type = WAGRMCNativeSkipQualifiers(raw)[0];
    return type == 'B' || type == 'c' || type == 'C';
}

static BOOL WAGRMCNativeMethodIsVoidNoArg(Method method) {
    return method && method_getNumberOfArguments(method) == 2 && WAGRMCNativeMethodReturnsVoid(method);
}

static NSString *WAGRMCNativeEncodingForMethod(Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"";
}

static NSString *WAGRMCNativeEncoding(id manager, NSString *selectorName) {
    if (!manager || !selectorName.length) return @"";
    return WAGRMCNativeEncodingForMethod(class_getInstanceMethod([manager class], NSSelectorFromString(selectorName)));
}

static id WAGRMCNativeCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMCNativeMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRMCNativeInvokeVoidNoArg(id manager, NSString *selectorName) {
    if (!manager || !selectorName.length) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([manager class], selector);
    if (!WAGRMCNativeMethodIsVoidNoArg(method)) return NO;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(manager, selector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSError *WAGRMCNativeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kWAGRMCNativeErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"MobileConfig native engine error"}];
}

BOOL WAGRMobileConfigNativeInvalidate(id userContext, NSString **outDiagnostic) {
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    if (!manager) {
        if (outDiagnostic) *outDiagnostic = @"UserSession manager unresolved; no invalidation was sent.";
        return NO;
    }

    NSMutableArray<NSString *> *invoked = [NSMutableArray array];
    if (WAGRMCNativeInvokeVoidNoArg(manager, @"invalidateCachedLatestContext")) {
        [invoked addObject:@"invalidateCachedLatestContext"];
    }
    // forceInvalidate is native teardown: it marks this object disposed,
    // clears the C++ manager/listeners, and is also called by -dealloc.

    NSString *diagnostic = [NSString stringWithFormat:
        @"manager=%@; localInvalidation=%@; setOverrides ABI=%@",
        NSStringFromClass([manager class]) ?: @"?",
        invoked.count ? [invoked componentsJoinedByString:@", "] : @"none",
        WAGRMCNativeEncoding(manager, @"setOverrides:").length
            ? WAGRMCNativeEncoding(manager, @"setOverrides:") : @"missing"];
    if (outDiagnostic) *outDiagnostic = diagnostic;
    WAGRLogAppendF(@"[MobileConfig][NativeEngine] %@", diagnostic);
    return invoked.count > 0;
}

BOOL WAGRMobileConfigNativeWriteOverrideDocument(NSDictionary<NSString *, id> *document,
                                                  id userContext,
                                                  BOOL mergeExisting,
                                                  NSError **outError,
                                                  NSString **outDiagnostic) {
    (void)document; (void)userContext; (void)mergeExisting;
    NSString *message = @"Blocked: mc_overrides.json belongs to FBMobileConfigOverridesTable. "
                         "The native C++ serializer/save ABI is not yet proven; WATweaks refuses direct JSON writes.";
    if (outError) *outError = WAGRMCNativeError(100, message);
    if (outDiagnostic) *outDiagnostic = message;
    WAGRLogAppendF(@"[MobileConfig][NativeEngine] compatibility JSON writer BLOCKED");
    return NO;
}

#pragma mark - Server fetch correlation

static NSObject *gWAGRMCFetchLock = nil;
static NSMutableDictionary<NSString *, id> *gWAGRMCFetchState = nil;
static NSString *gWAGRMCFetchToken = nil;
static NSTimeInterval gWAGRMCFetchStarted = 0;
static id gWAGRMCFetchContext = nil;
static id gWAGRMCFetchManager = nil;
static id gWAGRMCFetchExpectedPreferencesStore = nil;
static NSString *gWAGRMCFetchExpectedUnitId = nil;
static int gWAGRMCFetchExpectedUnitType = 0;
static WAGRMobileConfigNativeFetchCompletion gWAGRMCFetchCompletion = nil;
static void (*gWAGRMCXWA2SuccessOriginal)(id, SEL, id, id, id, long long, long long, id) = NULL;
static void (*gWAGRMCFetchSuccessMarkerOriginal)(id, SEL, id, int, id, id) = NULL;
static BOOL gWAGRMCXWA2SuccessHooked = NO;
static BOOL gWAGRMCFetchSuccessMarkerHooked = NO;

static void WAGRMCNativeEnsureFetchState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRMCFetchLock = [NSObject new];
        gWAGRMCFetchState = [NSMutableDictionary dictionaryWithObject:@"idle" forKey:@"state"];
    });
}

static NSDictionary *WAGRMCNativeFileState(NSString *path) {
    if (!path.length) return @{ @"path" : (id)NSNull.null, @"exists" : @NO };
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return @{ @"path" : path, @"exists" : @NO };
    NSDate *date = attrs[NSFileModificationDate];
    return @{
        @"path" : path,
        @"exists" : @YES,
        @"size" : attrs[NSFileSize] ?: @0,
        @"mtime" : date ? @([date timeIntervalSince1970]) : @0
    };
}

static id WAGRMCNativeBoundAccountManager(id context) {
    // The global capture resolver can return another account's most recently
    // observed manager. Account operations must follow this context's native
    // properties.mc route; a missing route is not permission to use that capture.
    if (!context) return nil;
    id properties = WAGRMCNativeCallObjectNoArg(context, @"abProperties");
    id manager = WAGRMCNativeCallObjectNoArg(properties, @"mc");
    Class expected = NSClassFromString(@"FBMobileConfigUserSessionContextManager");
    return expected && manager && [manager isKindOfClass:expected] ? manager : nil;
}

static NSString *WAGRMCNativeLatestConfigPathForManager(id manager) {
    id pathValue = WAGRMCNativeCallObjectNoArg(manager, @"getLatestConfigFilePath");
    if ([pathValue isKindOfClass:NSString.class]) return pathValue;
    if ([pathValue isKindOfClass:NSURL.class]) return [(NSURL *)pathValue path];
    if ([pathValue respondsToSelector:@selector(path)]) {
        @try {
            id path = [pathValue path];
            if ([path isKindOfClass:NSString.class]) return path;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static NSString *WAGRMCNativeLatestConfigPath(id context) {
    return WAGRMCNativeLatestConfigPathForManager(WAGRMCNativeBoundAccountManager(context));
}

static BOOL WAGRMCNativeStringsDescribeEqual(id left, id right);

static NSDictionary *WAGRMCNativeLatestReleaseFetchEvent(NSTimeInterval start, int unitType, NSString *unitId) {
    NSDictionary *doc = WAGRABPropsReleaseNativeLinkageDiagnosticDocument();
    NSArray *events = [doc[@"events"] isKindOfClass:NSArray.class] ? doc[@"events"] : @[];
    for (NSDictionary *event in [events reverseObjectEnumerator]) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSTimeInterval time = [event[@"time"] doubleValue];
        if (time + 0.001 < start) break;
        NSString *kind = [event[@"kind"] isKindOfClass:NSString.class] ? event[@"kind"] : @"";
        if (([kind isEqualToString:@"xwa2_native_fetch_observed"] ||
             [kind isEqualToString:@"www_native_fetch_observed"]) &&
            [event[@"unitType"] isKindOfClass:NSNumber.class] &&
            [event[@"unitType"] intValue] == unitType &&
            WAGRMCNativeStringsDescribeEqual(event[@"unitId"], unitId)) return event;
    }
    return nil;
}

static BOOL WAGRMCNativeStringsDescribeEqual(id left, id right) {
    if (!left || !right) return NO;
    NSString *a = [left isKindOfClass:NSString.class] ? left : [left description];
    NSString *b = [right isKindOfClass:NSString.class] ? right : [right description];
    return a.length && b.length && [a isEqualToString:b];
}


static BOOL WAGRMCNativeArgumentIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRMCNativeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCNativeArgumentIsInt32(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRMCNativeSkipQualifiers(raw);
    return type[0] == 'i' || type[0] == 'I';
}

static NSString *WAGRMCNativeLastFetchPreferenceKey(Class cls,
                                                     NSString *selectorName,
                                                     int unitType,
                                                     id unitId) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRMCNativeMethodReturnsObject(method) ||
        !WAGRMCNativeArgumentIsInt32(method, 2) ||
        !WAGRMCNativeArgumentIsObject(method, 3)) return nil;
    @try {
        id value = ((id (*)(id, SEL, int, id))objc_msgSend)((id)cls, selector, unitType, unitId);
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id WAGRMCNativePreferenceObject(id store, NSString *key) {
    if (!store || !key.length) return nil;
    for (NSString *selectorName in @[@"objectForKey:", @"objectForKeyedSubscript:"]) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getInstanceMethod([store class], selector);
        if (!method || method_getNumberOfArguments(method) != 3 ||
            !WAGRMCNativeMethodReturnsObject(method) ||
            !WAGRMCNativeArgumentIsObject(method, 2)) continue;
        @try {
            return ((id (*)(id, SEL, id))objc_msgSend)(store, selector, key);
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static NSDictionary *WAGRMCNativeLastFetchPersistenceReadback(id preferencesStore,
                                                               int unitType,
                                                               id unitId,
                                                               id appVersion) {
    Class cls = NSClassFromString(@"WAMobileConfigLastFetchStore") ?: objc_getClass("WAMobileConfigLastFetchStore");
    NSString *fetchKey = WAGRMCNativeLastFetchPreferenceKey(
        cls, @"preferenceKeyForLastSuccessFetch:unitId:", unitType, unitId);
    NSString *versionKey = WAGRMCNativeLastFetchPreferenceKey(
        cls, @"preferenceKeyForLastSuccessFetchAppVersion:unitId:", unitType, unitId);
    id fetchValue = WAGRMCNativePreferenceObject(preferencesStore, fetchKey);
    id versionValue = WAGRMCNativePreferenceObject(preferencesStore, versionKey);
    BOOL fetchPresent = fetchKey.length && fetchValue != nil;
    BOOL versionPresent = versionKey.length && versionValue != nil;
    BOOL versionMatches = !appVersion || (versionPresent && WAGRMCNativeStringsDescribeEqual(versionValue, appVersion));
    BOOL verified = fetchPresent && versionMatches;
    return @{
        @"fetch_preference_key" : fetchKey ?: (id)NSNull.null,
        @"fetch_preference_value" : fetchValue ?: (id)NSNull.null,
        @"fetch_marker_present" : @(fetchPresent),
        @"app_version_preference_key" : versionKey ?: (id)NSNull.null,
        @"app_version_preference_value" : versionValue ?: (id)NSNull.null,
        @"app_version_marker_present" : @(versionPresent),
        @"app_version_matches" : @(versionMatches),
        @"persistent_success_marker_verified" : @(verified),
        @"policy" : @"Keys are resolved by WAMobileConfigLastFetchStore itself after its native setter returns; WATweaks does not synthesize mobileconfig2_* preference names."
    };
}

static NSDictionary *WAGRMCNativeXWA2ResponseSummary(id response, id error, id fetchType,
                                                       long long attemptIndex, long long maxAttempts) {
    NSMutableDictionary *result = [@{
        @"response_class" : response ? (NSStringFromClass([response class]) ?: @"?") : @"nil",
        @"error" : error ? ([error description] ?: @"error") : (id)NSNull.null,
        @"fetch_type" : fetchType ? ([fetchType description] ?: @"?") : (id)NSNull.null,
        @"attempt_index" : @(attemptIndex),
        @"max_attempts" : @(maxAttempts)
    } mutableCopy];
    id payload = WAGRMCNativeCallObjectNoArg(response, @"xwa2MobileConfigFetch");
    id json = WAGRMCNativeCallObjectNoArg(payload, @"fetchResultJson");
    id abKey = WAGRMCNativeCallObjectNoArg(payload, @"abKey");
    if ([json isKindOfClass:NSString.class]) {
        result[@"fetch_result_present"] = @YES;
        result[@"fetch_result_length"] = @([(NSString *)json length]);
        result[@"fetch_result_string_hash"] = @([(NSString *)json hash]);
    } else {
        result[@"fetch_result_present"] = @NO;
    }
    if (abKey) result[@"ab_key"] = [abKey description] ?: @"?";
    return result;
}

static void WAGRMCNativeFinishFetch(NSString *token, NSDictionary *extra) {
    WAGRMCNativeEnsureFetchState();
    WAGRMobileConfigNativeFetchCompletion completion = nil;
    NSMutableDictionary *result = nil;
    @synchronized (gWAGRMCFetchLock) {
        if (!token.length || ![gWAGRMCFetchToken isEqualToString:token]) return;
        result = [gWAGRMCFetchState mutableCopy] ?: [NSMutableDictionary dictionary];
        [result addEntriesFromDictionary:extra ?: @{}];
        result[@"finished_at"] = @([[NSDate date] timeIntervalSince1970]);
        gWAGRMCFetchState = result;
        completion = [gWAGRMCFetchCompletion copy];
        gWAGRMCFetchCompletion = nil;
        gWAGRMCFetchToken = nil;
        gWAGRMCFetchStarted = 0;
        gWAGRMCFetchContext = nil;
        gWAGRMCFetchManager = nil;
        gWAGRMCFetchExpectedPreferencesStore = nil;
        gWAGRMCFetchExpectedUnitId = nil;
        gWAGRMCFetchExpectedUnitType = 0;
    }
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion([result copy]); });
}

static void WAGRMCNativeXWA2Success(id self, SEL _cmd, id response, id error, id fetchType,
                                     long long attemptIndex, long long maxAttempts, id attemptCompletion) {
    if (gWAGRMCXWA2SuccessOriginal) {
        gWAGRMCXWA2SuccessOriginal(self, _cmd, response, error, fetchType, attemptIndex, maxAttempts, attemptCompletion);
    }
    // This callback has no unit ID. A response alone cannot complete an account
    // request; the native persisted-success marker below supplies that identity.
    // Only retain scoped diagnostic data when the fetcher's actual native ivar
    // points at the context captured before dispatch.
    Ivar contextIvar = class_getInstanceVariable([self class], "_context");
    const char *contextType = contextIvar ? ivar_getTypeEncoding(contextIvar) : NULL;
    id fetcherContext = contextType && contextType[0] == '@' ? object_getIvar(self, contextIvar) : nil;
    @synchronized (gWAGRMCFetchLock) {
        if (!gWAGRMCFetchToken.length || !fetcherContext || fetcherContext != gWAGRMCFetchContext) return;
        NSDictionary *summary = WAGRMCNativeXWA2ResponseSummary(response, error, fetchType, attemptIndex, maxAttempts);
        gWAGRMCFetchState[@"xwa2_response_observed"] = summary ?: @{};
    }
}

static BOOL WAGRMCNativeInstallXWA2SuccessObserver(void) {
    WAGRMCNativeEnsureFetchState();
    if (gWAGRMCXWA2SuccessHooked) return YES;
    Class cls = NSClassFromString(@"WAMobileConfigGraphQLFetcher") ?: objc_getClass("WAMobileConfigGraphQLFetcher");
    SEL selector = NSSelectorFromString(@"handleFetchSuccessResponse:error:fetchType:attemptIndex:maxAttempts:attemptCompletion:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 8 || !WAGRMCNativeMethodReturnsVoid(method)) return NO;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, "v64@0:8@16@24@32q40q48@?56") != 0) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)WAGRMCNativeXWA2Success) {
        gWAGRMCXWA2SuccessOriginal = (void (*)(id, SEL, id, id, id, long long, long long, id))current;
        method_setImplementation(method, (IMP)WAGRMCNativeXWA2Success);
    }
    gWAGRMCXWA2SuccessHooked = method_getImplementation(method) == (IMP)WAGRMCNativeXWA2Success;
    return gWAGRMCXWA2SuccessHooked;
}

static void WAGRMCNativeFetchSuccessMarker(id self, SEL _cmd,
                                           id preferencesStore, int unitType,
                                           id unitId, id appVersion) {
    if (gWAGRMCFetchSuccessMarkerOriginal) {
        gWAGRMCFetchSuccessMarkerOriginal(self, _cmd, preferencesStore, unitType, unitId, appVersion);
    }
    WAGRMCNativeEnsureFetchState();
    NSString *token = nil;
    NSTimeInterval started = 0;
    @synchronized (gWAGRMCFetchLock) {
        token = [gWAGRMCFetchToken copy];
        started = gWAGRMCFetchStarted;
    }
    if (!token.length) return;

    id manager = nil;
    id expectedStore = nil;
    NSString *expectedUnitId = nil;
    int expectedUnitType = 0;
    @synchronized (gWAGRMCFetchLock) {
        if (![gWAGRMCFetchToken isEqualToString:token]) return;
        manager = gWAGRMCFetchManager;
        expectedStore = gWAGRMCFetchExpectedPreferencesStore;
        expectedUnitId = gWAGRMCFetchExpectedUnitId;
        expectedUnitType = gWAGRMCFetchExpectedUnitType;
    }
    if (!WAGRMCFetchMarkerMatches(token.length > 0, expectedStore && preferencesStore == expectedStore,
                                  expectedUnitType, unitType,
                                  WAGRMCNativeStringsDescribeEqual(unitId, expectedUnitId))) return;
    NSDictionary *backend = WAGRMCNativeLatestReleaseFetchEvent(started, expectedUnitType, expectedUnitId);
    NSDictionary *file = WAGRMCNativeFileState(WAGRMCNativeLatestConfigPathForManager(manager));
    NSDictionary *persistentMarker = WAGRMCNativeLastFetchPersistenceReadback(
        preferencesStore, unitType, unitId, appVersion);
    BOOL persistentVerified = [persistentMarker[@"persistent_success_marker_verified"] boolValue];
    WAGRMCNativeFinishFetch(token, @{
        @"state" : persistentVerified ? @"verified_native_persisted_success_marker" : @"verified_native_success_marker",
        @"verified_server_response" : @YES,
        @"persistent_success_marker_verified" : @(persistentVerified),
        @"success_marker" : @{
            @"class" : NSStringFromClass([self class]) ?: @"?",
            @"unit_type" : @(unitType),
            @"unit_id" : unitId ? ([unitId description] ?: @"?") : (id)NSNull.null,
            @"app_version" : appVersion ? ([appVersion description] ?: @"?") : (id)NSNull.null,
            @"preferences_store_class" : preferencesStore ? (NSStringFromClass([preferencesStore class]) ?: @"?") : @"nil",
            @"persistence_readback" : persistentMarker ?: @{}
        },
        @"network_input" : backend ?: @{},
        @"latest_config_after" : file ?: @{}
    });
}

static BOOL WAGRMCNativeInstallFetchSuccessMarkerObserver(void) {
    WAGRMCNativeEnsureFetchState();
    if (gWAGRMCFetchSuccessMarkerHooked) return YES;
    Class cls = NSClassFromString(@"WAMobileConfigLastFetchStore") ?: objc_getClass("WAMobileConfigLastFetchStore");
    SEL selector = NSSelectorFromString(@"setLastSuccessFetchInPreferencesStore:unitType:unitId:appVersion:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 6 || !WAGRMCNativeMethodReturnsVoid(method)) return NO;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, "v44@0:8@16i24@28@36") != 0) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)WAGRMCNativeFetchSuccessMarker) {
        gWAGRMCFetchSuccessMarkerOriginal = (void (*)(id, SEL, id, int, id, id))current;
        method_setImplementation(method, (IMP)WAGRMCNativeFetchSuccessMarker);
    }
    gWAGRMCFetchSuccessMarkerHooked = method_getImplementation(method) == (IMP)WAGRMCNativeFetchSuccessMarker;
    return gWAGRMCFetchSuccessMarkerHooked;
}

BOOL WAGRMobileConfigNativeFetchAccount(id userContext,
                                        WAGRMobileConfigNativeFetchCompletion completion,
                                        NSString **outDiagnostic) {
    WAGRMCNativeEnsureFetchState();
    if (!WAGRMCNativeInstallXWA2SuccessObserver()) {
        if (outDiagnostic) *outDiagnostic = @"XWA2 success observer ABI is not supported by this installed WhatsApp build.";
        return NO;
    }
    if (!WAGRMCNativeInstallFetchSuccessMarkerObserver()) {
        if (outDiagnostic) *outDiagnostic = @"WAMobileConfigLastFetchStore success-marker ABI is not supported by this installed WhatsApp build.";
        return NO;
    }
    id context = userContext ?: WAGRCurrentUserContext();
    id chatManager = WAGRMCNativeCallObjectNoArg(context, @"chatManager");
    SEL modernSelector = NSSelectorFromString(@"fetchMobileConfig:stack:");
    SEL legacySelector = NSSelectorFromString(@"fetchMobileConfig:");
    Method modernMethod = chatManager ? class_getInstanceMethod([chatManager class], modernSelector) : NULL;
    Method legacyMethod = chatManager ? class_getInstanceMethod([chatManager class], legacySelector) : NULL;
    WAGRMCFetchRoute route = WAGRMCFetchSelectRoute(modernMethod ? method_getTypeEncoding(modernMethod) : NULL,
                                                  legacyMethod ? method_getTypeEncoding(legacyMethod) : NULL);
    if (route == WAGRMCFetchRouteUnavailable) {
        if (outDiagnostic) *outDiagnostic = @"WAContextMain.chatManager native MobileConfig fetch ABI unresolved.";
        return NO;
    }
    SEL selector = route == WAGRMCFetchRouteBoolStack ? modernSelector : legacySelector;
    Method method = route == WAGRMCFetchRouteBoolStack ? modernMethod : legacyMethod;
    id manager = WAGRMCNativeBoundAccountManager(context);
    id preferencesStore = WAGRMCNativeCallObjectNoArg(manager, @"preferencesStore");
    id rawUnitId = WAGRMCNativeCallObjectNoArg(manager, @"getUnitId");
    NSString *unitId = [rawUnitId isKindOfClass:NSString.class] ? rawUnitId : nil;
    Method unitTypeMethod = manager ? class_getInstanceMethod([manager class], NSSelectorFromString(@"getUnitType")) : NULL;
    int unitType = 0;
    if (unitTypeMethod && strcmp(method_getTypeEncoding(unitTypeMethod), "i16@0:8") == 0) {
        @try { unitType = ((int (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"getUnitType")); }
        @catch (__unused NSException *exception) { unitType = 0; }
    }
    if (!context || !preferencesStore || !unitId.length || unitType != WAGRMCFetchUserSessionUnitType) {
        if (outDiagnostic) *outDiagnostic = @"Live UserSession identity/preferencesStore unresolved; account fetch was not dispatched.";
        return NO;
    }
    NSString *entrypoint = route == WAGRMCFetchRouteBoolStack
        ? @"WAChatManager fetchMobileConfig:NO stack:-1" : @"WAChatManager fetchMobileConfig:NO";

    NSString *token = NSUUID.UUID.UUIDString;
    NSTimeInterval started = [[NSDate date] timeIntervalSince1970];
    NSString *latestPath = WAGRMCNativeLatestConfigPathForManager(manager);
    NSDictionary *before = WAGRMCNativeFileState(latestPath);
    @synchronized (gWAGRMCFetchLock) {
        if (gWAGRMCFetchToken.length) {
            if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"MobileConfig fetch already active: %@", gWAGRMCFetchToken];
            return NO;
        }
        gWAGRMCFetchToken = token;
        gWAGRMCFetchStarted = started;
        gWAGRMCFetchContext = context;
        gWAGRMCFetchManager = manager;
        gWAGRMCFetchExpectedPreferencesStore = preferencesStore;
        gWAGRMCFetchExpectedUnitId = [unitId copy];
        gWAGRMCFetchExpectedUnitType = unitType;
        gWAGRMCFetchCompletion = [completion copy];
        gWAGRMCFetchState = [@{
            @"schema" : @"watweaks_mobileconfig_native_fetch_v1",
            @"state" : @"requesting",
            @"token" : token,
            @"started_at" : @(started),
            @"context_class" : context ? (NSStringFromClass([context class]) ?: @"?") : @"nil",
            @"chat_manager_class" : NSStringFromClass([chatManager class]) ?: @"?",
            @"entrypoint" : entrypoint,
            @"expected_unit_type" : @(unitType),
            @"expected_unit_id" : unitId,
            @"native_stack" : route == WAGRMCFetchRouteBoolStack ? @(WAGRMCFetchNativeStackAutomatic) : (id)NSNull.null,
            @"latest_config_before" : before,
            @"policy" : @"Normal authenticated fetch. WATweaks does not construct WAMobileConfigFetchInput, GraphQL, access tokens, or hashes; the native pipeline supplies globalValueHash/epRefreshId."
        } mutableCopy];
    }

    @try {
        if (route == WAGRMCFetchRouteBoolStack) {
            ((void (*)(id, SEL, BOOL, int))objc_msgSend)(chatManager, selector, NO, WAGRMCFetchNativeStackAutomatic);
        } else {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(chatManager, selector, NO);
        }
    } @catch (NSException *exception) {
        WAGRMCNativeFinishFetch(token, @{
            @"state" : @"entrypoint_exception",
            @"verified_server_response" : @NO,
            @"exception" : exception.reason ?: @"exception"
        });
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"fetchMobileConfig:NO threw %@", exception.reason ?: @"exception"];
        return NO;
    }

    if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"Native MobileConfig fetch started token=%@ via %@ (%s)",
        token, NSStringFromClass([chatManager class]) ?: @"?", method_getTypeEncoding(method) ?: "?"];
    WAGRLogAppendF(@"[MobileConfig][NativeFetch] started %@", token);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *backend = WAGRMCNativeLatestReleaseFetchEvent(started, unitType, unitId);
        NSDictionary *file = WAGRMCNativeFileState(WAGRMCNativeLatestConfigPathForManager(manager));
        WAGRMCNativeFinishFetch(token, @{
            @"state" : backend ? @"timeout_after_network_request" : @"timeout_before_network_observed",
            @"verified_server_response" : @NO,
            @"network_input" : backend ?: @{},
            @"latest_config_after" : file ?: @{}
        });
    });
    return YES;
}

NSDictionary<NSString *, id> *WAGRMobileConfigNativeFetchState(void) {
    WAGRMCNativeEnsureFetchState();
    @synchronized (gWAGRMCFetchLock) { return [gWAGRMCFetchState copy] ?: @{}; }
}

#pragma mark - Diagnostics

NSDictionary<NSString *, id> *WAGRMobileConfigNativeEngineDiagnosticDocument(id userContext) {
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    NSString *setOverridesEncoding = WAGRMCNativeEncoding(manager, @"setOverrides:");
    BOOL sharedPtrABI = [setOverridesEncoding containsString:@"shared_ptr"] ||
                        [setOverridesEncoding containsString:@"FBMobileConfigOverridesTable"];
    Class startupClass = NSClassFromString(@"FBMobileConfigStartupConfigs") ?: objc_getClass("FBMobileConfigStartupConfigs");
    id startup = nil;
    Method getInstance = startupClass ? class_getClassMethod(startupClass, NSSelectorFromString(@"getInstance")) : NULL;
    if (getInstance && method_getNumberOfArguments(getInstance) == 2 && WAGRMCNativeMethodReturnsObject(getInstance)) {
        @try { startup = ((id (*)(id, SEL))objc_msgSend)((id)startupClass, NSSelectorFromString(@"getInstance")); }
        @catch (__unused NSException *exception) { startup = nil; }
    }
    Method startupSet = startup ? class_getInstanceMethod([startup class], NSSelectorFromString(@"setOverrideForParam:andValue:")) : NULL;
    return @{
        @"user_session_resolved" : @(manager != nil),
        @"manager_class" : manager ? (NSStringFromClass([manager class]) ?: @"?") : @"nil",
        @"overrides_path" : WAGRMobileConfigOverridesPath(userContext) ?: (id)NSNull.null,
        @"latest_config_path" : WAGRMCNativeLatestConfigPath(userContext) ?: (id)NSNull.null,
        @"get_overrides_path_encoding" : WAGRMCNativeEncoding(manager, @"getOverridesTablePath"),
        @"overrides_getter_encoding" : WAGRMCNativeEncoding(manager, @"overrides"),
        @"set_overrides_encoding" : setOverridesEncoding ?: @"",
        @"set_overrides_is_cpp_shared_ptr_abi" : @(sharedPtrABI),
        @"direct_set_overrides_call_enabled" : @NO,
        @"compat_json_writer_available" : @NO,
        @"compat_json_writer_blocked" : @YES,
        @"main_overrides_table_serializer_proven" : @NO,
        @"startup_set_override_encoding" : WAGRMCNativeEncodingForMethod(startupSet),
        @"xwa2_success_observer_installed" : @(gWAGRMCXWA2SuccessHooked),
        @"native_success_marker_observer_installed" : @(gWAGRMCFetchSuccessMarkerHooked),
        @"fetch_state" : WAGRMobileConfigNativeFetchState(),
        @"invalidate_cached_latest_context_encoding" : WAGRMCNativeEncoding(manager, @"invalidateCachedLatestContext"),
        @"force_invalidate_encoding" : WAGRMCNativeEncoding(manager, @"forceInvalidate"),
        @"force_invalidate_role" : @"Native manager teardown; never used for local cache refresh",
        @"force_refresh_config_encoding" : WAGRMCNativeEncoding(manager, @"forceRefreshOfConfig:"),
        @"policy" : @"ABProp local overrides use FBMobileConfigStartupConfigs and exact App Group readback; server fetch selects the validated WAChatManager ABI (26.40: fetchMobileConfig:NO stack:-1). Direct mc_overrides.json writes remain blocked until the FBMobileConfigOverridesTable C++ serializer is proven."
    };
}

NSString *WAGRMobileConfigNativeEngineDiagnosticText(id userContext) {
    NSDictionary *document = WAGRMobileConfigNativeEngineDiagnosticDocument(userContext);
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted error:nil];
    return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : [document description];
}
