#import "WAGRABPropsABTLiveService.h"
#import "WAGRABPropsNativeStore.h"
#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <string.h>

static NSString * const kManagerClass = @"XMPPConnectionABPropsRequestManager";
static NSString * const kRequestClass = @"XMPPRequestABProperties";
static NSString * const kTopSelector = @"requestFreshABProps:withCompletion:";
static NSString * const kLowerSelector = @"requestFreshABPropsWithGroupJID:deltaUpdate:completion:";
static NSString * const kDidSucceedSelector = @"didSucceedWithResponse:";
static NSString * const kHandleSelector = @"handleABPropsResponseForGroupJID:error:props:samplingWeights:protocolVersion:configKey:configHash:refreshInterval:refreshID:encryptedRID:isDeltaUpdate:attemptIndex:maxAttempts:attemptCompletion:";

static const char *kTopEncoding = "v28@0:8B16@?20";
static const char *kLowerEncoding = "v36@0:8@16B24@?28";
static const char *kDidSucceedEncoding = "v24@0:8@16";
static const char *kHandleEncoding = "v120@0:8@16@24@32@40i48@52@60q68@76@84B92q96q104@?112";

static void (*gOriginalLower)(id, SEL, id, BOOL, id) = NULL;
static void (*gOriginalDidSucceed)(id, SEL, id) = NULL;
static void (*gOriginalHandle)(id, SEL, id, id, id, id, int, id, id,
                               int64_t, id, id, BOOL, int64_t, int64_t, id) = NULL;
static BOOL gInstalled = NO;

static NSObject *gLock;
static BOOL gPending = NO;
static BOOL gDispatchArmed = NO;
static __weak id gPendingManager = nil;
static NSString *gToken;
static NSTimeInterval gStartTime = 0;
static NSTimeInterval gLowerEnteredTime = 0;
static NSTimeInterval gNativeCompletionTime = 0;
static NSDictionary *gRequest;
static NSDictionary *gDidSucceed;
static NSDictionary *gDecoded;
static NSDictionary *gResult;
static NSMutableArray<NSDictionary *> *gEvents;
static WAGRABPropsABTLiveCompletion gCompletion;
static NSString *gBeforeFingerprint;

static void EnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSObject new];
        gEvents = [NSMutableArray array];
        gResult = @{
            @"schema": @"watweaks_abprops_abt_live_service_v1",
            @"outcome": @"not_run"
        };
    });
}

static NSTimeInterval Now(void) { return NSDate.date.timeIntervalSince1970; }
static NSString *ClassName(id value) { return value ? (NSStringFromClass([value class]) ?: @"?") : @"nil"; }

static BOOL EncodingMatches(Method method, const char *expected) {
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && expected && strcmp(actual, expected) == 0;
}

static NSString *Encoding(Class cls, NSString *selectorName) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) : NULL;
    const char *raw = method ? method_getTypeEncoding(method) : NULL;
    return raw ? ([NSString stringWithUTF8String:raw] ?: @"") : @"";
}

static void Event(NSString *name, NSDictionary *fields) {
    EnsureState();
    NSMutableDictionary *row = [@{ @"time": @(Now()), @"event": name ?: @"?" } mutableCopy];
    if ([fields isKindOfClass:NSDictionary.class]) [row addEntriesFromDictionary:fields];
    @synchronized (gLock) {
        [gEvents addObject:row];
        if (gEvents.count > 64) [gEvents removeObjectsInRange:NSMakeRange(0, gEvents.count - 64)];
    }
}

static id CallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char ret[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    if (ret[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id ResolveManager(id context) {
    id root = context ?: WAGRCurrentUserContext();
    if (!root) return nil;
    id manager = CallObjectNoArg(root, @"xmppConnectionABPropsRequestManager");
    if (manager && EncodingMatches(class_getInstanceMethod([manager class], NSSelectorFromString(kTopSelector)), kTopEncoding)) return manager;
    id provider = CallObjectNoArg(root, @"networkingDependencyProvider");
    if (!provider) provider = CallObjectNoArg(root, @"networking");
    id connection = CallObjectNoArg(provider, @"xmppConnection");
    if (!connection) connection = CallObjectNoArg(root, @"xmppConnection");
    manager = CallObjectNoArg(connection, @"xmppConnectionABPropsRequestManager");
    if (!manager) manager = CallObjectNoArg(provider, @"xmppConnectionABPropsRequestManager");
    if (manager && EncodingMatches(class_getInstanceMethod([manager class], NSSelectorFromString(kTopSelector)), kTopEncoding)) return manager;
    return nil;
}

static id ReadNoArg(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char raw[32] = {0}; method_getReturnType(method, raw, sizeof(raw));
    @try {
        switch (raw[0]) {
            case '@': return ((id (*)(id, SEL))objc_msgSend)(object, selector);
            case 'B': return @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector));
            case 'c': return @(((char (*)(id, SEL))objc_msgSend)(object, selector));
            case 'C': return @(((unsigned char (*)(id, SEL))objc_msgSend)(object, selector));
            case 'i': return @(((int (*)(id, SEL))objc_msgSend)(object, selector));
            case 'I': return @(((unsigned int (*)(id, SEL))objc_msgSend)(object, selector));
            case 'q': return @(((long long (*)(id, SEL))objc_msgSend)(object, selector));
            case 'Q': return @(((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector));
            case 'd': return @(((double (*)(id, SEL))objc_msgSend)(object, selector));
            default: return nil;
        }
    } @catch (__unused NSException *exception) { return nil; }
}

static id JSONSafe(id value, NSUInteger depth) {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 7) return [[value description] substringToIndex:MIN((NSUInteger)256, [value description].length)];
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSError.class]) {
        NSError *error = value;
        return @{ @"domain": error.domain ?: @"", @"code": @(error.code), @"description": error.localizedDescription ?: @"" };
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) [out addObject:JSONSafe(item, depth + 1) ?: NSNull.null];
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            NSString *safeKey = [key isKindOfClass:NSString.class] ? key : [key description];
            if (safeKey.length) out[safeKey] = JSONSafe(obj, depth + 1) ?: NSNull.null;
        }];
        return out;
    }
    NSMutableDictionary *known = [NSMutableDictionary dictionary];
    for (NSString *field in @[@"key", @"value", @"expoKey", @"configCode", @"configValue", @"configExpoKey", @"eventCode", @"samplingWeight"]) {
        id fieldValue = ReadNoArg(value, field);
        if (fieldValue) known[field] = JSONSafe(fieldValue, depth + 1) ?: NSNull.null;
    }
    if (known.count) {
        known[@"_class"] = ClassName(value);
        return known;
    }
    NSString *description = nil;
    @try { description = [value description]; } @catch (__unused NSException *exception) {}
    if (description.length > 512) description = [[description substringToIndex:512] stringByAppendingString:@"…"];
    return @{ @"_class": ClassName(value), @"description": description ?: @"?" };
}

static NSUInteger Count(id value) {
    if ([value respondsToSelector:@selector(count)]) {
        @try { return (NSUInteger)[value count]; } @catch (__unused NSException *exception) {}
    }
    return value ? 1 : 0;
}

static id MetadataValue(NSDictionary *metadata, NSArray<NSString *> *keys) {
    for (NSString *key in keys) if (metadata[key]) return metadata[key];
    return nil;
}

static NSString *StringValue(id value) {
    if (!value || value == NSNull.null) return nil;
    if ([value isKindOfClass:NSString.class]) return value;
    return [value description];
}

static BOOL SameValue(id a, id b) {
    NSString *left = StringValue(a), *right = StringValue(b);
    return left.length && right.length && [left isEqualToString:right];
}

static NSDictionary *SnapshotSummary(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{ @"available": @NO };
    NSDictionary *metadata = snapshot.metadata ?: @{};
    NSMutableDictionary *out = [@{
        @"available": @YES,
        @"prop_count": @(snapshot.numericPropCount),
        @"fingerprint": snapshot.fingerprint ?: @"",
        @"payload_key": snapshot.payloadKey.length ? @"gabp.<account>p" : @"",
        @"metadata_key": snapshot.metadataKey.length ? @"gabp.<account>c" : @""
    } mutableCopy];
    id hash = MetadataValue(metadata, @[@"hash", @"configHash"]);
    id refreshID = MetadataValue(metadata, @[@"refreshID", @"refreshId", @"refresh_id"]);
    id encryptedRID = MetadataValue(metadata, @[@"encryptedRID", @"encryptedRid", @"erid"]);
    id interval = MetadataValue(metadata, @[@"refreshInterval", @"refresh"]);
    if (hash) out[@"hash"] = JSONSafe(hash, 0);
    if (refreshID) out[@"refresh_id"] = JSONSafe(refreshID, 0);
    if (encryptedRID) out[@"encrypted_rid"] = JSONSafe(encryptedRID, 0);
    if (interval) out[@"refresh_interval"] = JSONSafe(interval, 0);
    return out;
}

static NSDictionary *BuildFinalResult(void) {
    NSDictionary *request = nil, *didSucceed = nil, *decoded = nil;
    NSString *beforeFingerprint = nil, *token = nil;
    NSTimeInterval lowerTime = 0, completionTime = 0;
    @synchronized (gLock) {
        request = [gRequest copy] ?: @{};
        didSucceed = [gDidSucceed copy] ?: @{};
        decoded = [gDecoded copy] ?: @{};
        beforeFingerprint = [gBeforeFingerprint copy] ?: @"";
        token = [gToken copy] ?: @"";
        lowerTime = gLowerEnteredTime;
        completionTime = gNativeCompletionTime;
    }

    WAGRABPropsNativeSnapshot *after = WAGRABPropsReadNativeSnapshot(NULL);
    NSDictionary *metadata = after.metadata ?: @{};
    id configHash = decoded[@"config_hash"];
    id refreshID = decoded[@"refresh_id"];
    id encryptedRID = decoded[@"encrypted_rid"];
    BOOL hashMatch = configHash && configHash != NSNull.null ? SameValue(configHash, MetadataValue(metadata, @[@"hash", @"configHash"])) : YES;
    BOOL refreshMatch = refreshID && refreshID != NSNull.null ? SameValue(refreshID, MetadataValue(metadata, @[@"refreshID", @"refreshId", @"refresh_id"])) : YES;
    BOOL eridMatch = encryptedRID && encryptedRID != NSNull.null ? SameValue(encryptedRID, MetadataValue(metadata, @[@"encryptedRID", @"encryptedRid", @"erid"])) : YES;
    BOOL fingerprintChanged = after.fingerprint.length && beforeFingerprint.length && ![after.fingerprint isEqualToString:beforeFingerprint];
    NSUInteger wireCount = [decoded[@"prop_count"] unsignedIntegerValue];
    BOOL delta = [decoded[@"delta_update"] boolValue];
    NSString *effectiveSource = wireCount == 0 ? @"WAPropertiesStore after successful no-change response"
        : (delta ? @"wire delta + WAPropertiesStore merged state" : @"wire full response + WAPropertiesStore confirmed state");

    NSDictionary *effectiveDocument = after ? (WAGRABPropsNativeExportDocument(after) ?: @{}) : @{};
    NSDictionary *result = @{
        @"schema": @"watweaks_abprops_abt_live_service_v1",
        @"token": token,
        @"outcome": decoded.count ? @"native_completion_with_correlated_handler" : @"native_completion_without_correlated_handler",
        @"request": request,
        @"lower_request_entered": @(lowerTime > 0),
        @"lower_request_entered_time": @(lowerTime),
        @"native_completion_time": @(completionTime),
        @"did_succeed_response": didSucceed,
        @"decoded_response": decoded,
        @"wire_prop_count": @(wireCount),
        @"effective_prop_count": @(after.numericPropCount),
        @"effective_source": effectiveSource,
        @"effective_snapshot": effectiveDocument,
        @"store_confirmation": @{
            @"available": @(after != nil),
            @"fingerprint_changed": @(fingerprintChanged),
            @"config_hash_matches": @(hashMatch),
            @"refresh_id_matches": @(refreshMatch),
            @"encrypted_rid_matches": @(eridMatch),
            @"metadata_matches": @(hashMatch && refreshMatch && eridMatch),
            @"after": SnapshotSummary(after)
        },
        @"events": [gEvents copy] ?: @[]
    };
    return result;
}

static void Finish(void) {
    WAGRABPropsABTLiveCompletion completion = nil;
    NSDictionary *result = BuildFinalResult();
    @synchronized (gLock) {
        gResult = result;
        completion = [gCompletion copy];
        gCompletion = nil;
        gPending = NO;
        gDispatchArmed = NO;
        gPendingManager = nil;
    }
    Event(@"explicit_transaction_finished", @{
        @"wire_prop_count": result[@"wire_prop_count"] ?: @0,
        @"effective_prop_count": result[@"effective_prop_count"] ?: @0,
        @"outcome": result[@"outcome"] ?: @"?"
    });
    WAGRLogAppendF(@"[ABProps][ABTLive] wire=%@ effective=%@ outcome=%@",
                   result[@"wire_prop_count"] ?: @0,
                   result[@"effective_prop_count"] ?: @0,
                   result[@"outcome"] ?: @"?");
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
}

static void LowerHook(id self, SEL _cmd, id groupJID, BOOL deltaUpdate, id completion) {
    BOOL belongs = NO;
    @synchronized (gLock) {
        belongs = gPending && gDispatchArmed && self == gPendingManager;
        if (belongs) gLowerEnteredTime = Now();
    }
    if (!belongs) {
        if (gOriginalLower) gOriginalLower(self, _cmd, groupJID, deltaUpdate, completion);
        return;
    }

    Event(@"explicit_lower_request_entered", @{
        @"manager_class": ClassName(self),
        @"group_jid": JSONSafe(groupJID, 0),
        @"delta_update": @(deltaUpdate)
    });

    void (^originalCompletion)(void) = [completion copy];
    void (^wrappedCompletion)(void) = ^{
        @synchronized (gLock) { gNativeCompletionTime = Now(); }
        Event(@"explicit_native_completion", @{});
        if (originalCompletion) originalCompletion();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ Finish(); });
    };
    if (gOriginalLower) gOriginalLower(self, _cmd, groupJID, deltaUpdate, wrappedCompletion);
}

static void DidSucceedHook(id self, SEL _cmd, id response) {
    BOOL candidate = NO;
    @synchronized (gLock) { candidate = gPending && gLowerEnteredTime > 0 && gNativeCompletionTime == 0; }
    if (candidate) {
        NSDictionary *record = @{
            @"time": @(Now()),
            @"request_class": ClassName(self),
            @"response_class": ClassName(response),
            @"response_description": [[response description] ?: @"" substringToIndex:MIN((NSUInteger)1024, [[response description] ?: @"" length])]
        };
        @synchronized (gLock) { gDidSucceed = record; }
        Event(@"explicit_did_succeed_candidate", record);
    }
    if (gOriginalDidSucceed) gOriginalDidSucceed(self, _cmd, response);
}

static void HandleHook(id self, SEL _cmd,
                       id groupJID, id error, id props, id samplingWeights,
                       int protocolVersion, id configKey, id configHash,
                       int64_t refreshInterval, id refreshID, id encryptedRID,
                       BOOL isDeltaUpdate, int64_t attemptIndex, int64_t maxAttempts,
                       id attemptCompletion) {
    if (gOriginalHandle) {
        gOriginalHandle(self, _cmd, groupJID, error, props, samplingWeights,
                        protocolVersion, configKey, configHash, refreshInterval,
                        refreshID, encryptedRID, isDeltaUpdate, attemptIndex,
                        maxAttempts, attemptCompletion);
    }

    BOOL candidate = NO;
    @synchronized (gLock) {
        candidate = gPending && self == gPendingManager && !groupJID &&
                    gLowerEnteredTime > 0 && gNativeCompletionTime == 0;
    }
    if (!candidate) return;

    NSDictionary *decoded = @{
        @"time": @(Now()),
        @"manager_class": ClassName(self),
        @"group_jid": JSONSafe(groupJID, 0),
        @"error": JSONSafe(error, 0),
        @"props": JSONSafe(props, 0),
        @"prop_count": @(Count(props)),
        @"sampling_weights": JSONSafe(samplingWeights, 0),
        @"sampling_count": @(Count(samplingWeights)),
        @"protocol_version": @(protocolVersion),
        @"config_key": JSONSafe(configKey, 0),
        @"config_hash": JSONSafe(configHash, 0),
        @"refresh_interval": @(refreshInterval),
        @"refresh_id": JSONSafe(refreshID, 0),
        @"encrypted_rid": JSONSafe(encryptedRID, 0),
        @"delta_update": @(isDeltaUpdate),
        @"attempt_index": @(attemptIndex),
        @"max_attempts": @(maxAttempts)
    };
    @synchronized (gLock) { gDecoded = decoded; }
    Event(@"explicit_decoded_handler_candidate", @{
        @"prop_count": @(Count(props)),
        @"sampling_count": @(Count(samplingWeights)),
        @"delta_update": @(isDeltaUpdate),
        @"has_error": @(error != nil)
    });
}

static BOOL InstallHooks(void) {
    EnsureState();
    if (gInstalled) return YES;
    Class managerClass = NSClassFromString(kManagerClass) ?: objc_getClass(kManagerClass.UTF8String);
    Class requestClass = NSClassFromString(kRequestClass) ?: objc_getClass(kRequestClass.UTF8String);
    Method lower = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kLowerSelector)) : NULL;
    Method did = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kDidSucceedSelector)) : NULL;
    Method handle = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kHandleSelector)) : NULL;
    if (!EncodingMatches(lower, kLowerEncoding) || !EncodingMatches(did, kDidSucceedEncoding) || !EncodingMatches(handle, kHandleEncoding)) return NO;

    IMP lowerCurrent = method_getImplementation(lower);
    IMP didCurrent = method_getImplementation(did);
    IMP handleCurrent = method_getImplementation(handle);
    if (!lowerCurrent || !didCurrent || !handleCurrent) return NO;
    gOriginalLower = (void (*)(id, SEL, id, BOOL, id))lowerCurrent;
    gOriginalDidSucceed = (void (*)(id, SEL, id))didCurrent;
    gOriginalHandle = (void (*)(id, SEL, id, id, id, id, int, id, id, int64_t, id, id, BOOL, int64_t, int64_t, id))handleCurrent;
    method_setImplementation(lower, (IMP)LowerHook);
    method_setImplementation(did, (IMP)DidSucceedHook);
    method_setImplementation(handle, (IMP)HandleHook);
    gInstalled = YES;
    Event(@"correlation_hooks_installed", @{
        @"lower_encoding": Encoding(managerClass, kLowerSelector),
        @"did_succeed_encoding": Encoding(requestClass, kDidSucceedSelector),
        @"handler_encoding": Encoding(managerClass, kHandleSelector)
    });
    return YES;
}

BOOL WAGRABPropsABTLiveFetch(id userContext,
                             WAGRABPropsABTLiveCompletion completion,
                             NSString **diagnostic) {
    EnsureState();
    if (!InstallHooks()) {
        NSString *text = @"ABT live correlation hooks unavailable or ABI mismatch";
        if (diagnostic) *diagnostic = text;
        return NO;
    }
    id context = userContext ?: WAGRCurrentUserContext();
    id manager = ResolveManager(context);
    if (!manager) {
        NSString *text = @"live XMPPConnectionABPropsRequestManager unresolved";
        if (diagnostic) *diagnostic = text;
        return NO;
    }
    Method top = class_getInstanceMethod([manager class], NSSelectorFromString(kTopSelector));
    if (!EncodingMatches(top, kTopEncoding)) {
        NSString *text = [NSString stringWithFormat:@"requestFreshABProps ABI mismatch: %@", Encoding([manager class], kTopSelector)];
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    WAGRABPropsNativeSnapshot *before = WAGRABPropsReadNativeSnapshot(NULL);
    NSString *token = NSUUID.UUID.UUIDString;
    @synchronized (gLock) {
        if (gPending) {
            if (diagnostic) *diagnostic = @"another correlated ABT transaction is still pending";
            return NO;
        }
        gPending = YES;
        gDispatchArmed = YES;
        gPendingManager = manager;
        gToken = token;
        gStartTime = Now();
        gLowerEnteredTime = 0;
        gNativeCompletionTime = 0;
        gDidSucceed = nil;
        gDecoded = nil;
        gBeforeFingerprint = before.fingerprint ?: @"";
        gCompletion = [completion copy];
        [gEvents removeAllObjects];
        gRequest = @{
            @"token": token,
            @"time": @(gStartTime),
            @"context_class": ClassName(context),
            @"manager_class": ClassName(manager),
            @"top_selector": kTopSelector,
            @"top_encoding": Encoding([manager class], kTopSelector),
            @"lower_selector": kLowerSelector,
            @"lower_encoding": Encoding([manager class], kLowerSelector),
            @"delta_update_requested": @NO,
            @"before": SnapshotSummary(before)
        };
    }

    Event(@"explicit_transaction_started", @{ @"token": token });
    void (^topCompletion)(void) = ^{ Event(@"explicit_top_completion_forwarded", @{ @"token": token }); };
    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, NSSelectorFromString(kTopSelector), NO, topCompletion);
    } @catch (NSException *exception) {
        @synchronized (gLock) { gPending = NO; gDispatchArmed = NO; gPendingManager = nil; gCompletion = nil; }
        NSString *text = [NSString stringWithFormat:@"native ABT request threw %@", exception.reason ?: @"exception"];
        if (diagnostic) *diagnostic = text;
        return NO;
    }
    @synchronized (gLock) { gDispatchArmed = NO; }

    BOOL lowerEntered = NO;
    @synchronized (gLock) { lowerEntered = gLowerEnteredTime > 0; }
    if (!lowerEntered) {
        @synchronized (gLock) { gPending = NO; gPendingManager = nil; gCompletion = nil; }
        NSString *text = @"requestFreshABProps returned without entering the exact lower native request method";
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    NSString *text = [NSString stringWithFormat:@"correlated ABT request %@ entered %@; awaiting exact native completion", token, kLowerSelector];
    if (diagnostic) *diagnostic = text;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL timeout = NO;
        @synchronized (gLock) { timeout = gPending && [gToken isEqualToString:token] && gNativeCompletionTime == 0; }
        if (!timeout) return;
        Event(@"explicit_transaction_timeout", @{ @"token": token });
        NSDictionary *fallback = BuildFinalResult();
        @synchronized (gLock) {
            NSMutableDictionary *mutable = [fallback mutableCopy];
            mutable[@"outcome"] = @"timeout_waiting_exact_native_completion";
            gResult = mutable;
            WAGRABPropsABTLiveCompletion callback = [gCompletion copy];
            gCompletion = nil; gPending = NO; gPendingManager = nil;
            if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(mutable); });
        }
    });
    return YES;
}

NSDictionary<NSString *, id> *WAGRABPropsABTLiveServiceDocument(void) {
    EnsureState();
    @synchronized (gLock) {
        if (gPending) {
            NSMutableDictionary *pending = [gResult mutableCopy] ?: [NSMutableDictionary dictionary];
            pending[@"schema"] = @"watweaks_abprops_abt_live_service_v1";
            pending[@"outcome"] = @"pending";
            pending[@"request"] = gRequest ?: @{};
            pending[@"lower_request_entered"] = @(gLowerEnteredTime > 0);
            pending[@"did_succeed_response"] = gDidSucceed ?: @{};
            pending[@"decoded_response"] = gDecoded ?: @{};
            pending[@"events"] = [gEvents copy] ?: @[];
            return pending;
        }
        return [gResult copy] ?: @{};
    }
}

__attribute__((constructor))
static void WAGRABPropsABTLiveServiceCtor(void) {
    @autoreleasepool {
        // Install after the general ABT observer has completed its bounded retry
        // window, so our wrappers remain outermost and chain into it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ (void)InstallHooks(); });
    }
}
