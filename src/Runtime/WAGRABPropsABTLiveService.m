#import "WAGRABPropsABTLiveService.h"
#import "WAGRABPropsABTTransactionGate.h"
#import "WAGRABPropsNativeStore.h"
#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <string.h>

NSString * const WAGRABPropsABTVariantRegularHash = @"regular_hash";
NSString * const WAGRABPropsABTVariantDeltaRefreshID = @"delta_refresh_id";
NSString * const WAGRABPropsABTVariantFullEmptyHash = @"full_empty_hash";
NSString * const WAGRABPropsABTVariantFullNoValidators = @"full_no_validators";
NSString * const WAGRABPropsABTVariantCustomWire = @"custom_wire";

static NSString * const kManagerClass = @"XMPPConnectionABPropsRequestManager";
static NSString * const kRequestClass = @"XMPPRequestABProperties";
static NSString * const kTopSelector = @"requestFreshABProps:withCompletion:";
static NSString * const kLowerSelector = @"requestFreshABPropsWithGroupJID:deltaUpdate:completion:";
static NSString * const kRequestInitSelector = @"initWithUserContext:groupJID:configHash:refreshID:completion:";
static NSString * const kDidSucceedSelector = @"didSucceedWithResponse:";
static NSString * const kDidFailSelector = @"didFailWithError:";
static NSString * const kHandleSelector = @"handleABPropsResponseForGroupJID:error:props:samplingWeights:protocolVersion:configKey:configHash:refreshInterval:refreshID:encryptedRID:isDeltaUpdate:attemptIndex:maxAttempts:attemptCompletion:";

static const char *kTopEncoding = "v28@0:8B16@?20";
static const char *kLowerEncoding = "v36@0:8@16B24@?28";
static const char *kRequestInitEncoding = "@56@0:8@16@24@32@40@?48";
static const char *kDidSucceedEncoding = "v24@0:8@16";
static const char *kDidFailEncoding = "v24@0:8@16";
static const char *kHandleEncoding = "v120@0:8@16@24@32@40i48@52@60q68@76@84B92q96q104@?112";

static void (*gOriginalLower)(id, SEL, id, BOOL, id) = NULL;
static id (*gOriginalRequestInit)(id, SEL, id, id, id, id, id) = NULL;
static void (*gOriginalDidSucceed)(id, SEL, id) = NULL;
static void (*gOriginalDidFail)(id, SEL, id) = NULL;
static void (*gOriginalHandle)(id, SEL, id, id, id, id, int, id, id,
                               int64_t, id, id, BOOL, int64_t, int64_t, id) = NULL;
static BOOL gInstalled = NO;

static NSObject *gLock;
static BOOL gPending = NO;
static BOOL gDispatchArmed = NO;
static __weak id gPendingManager = nil;
static __weak id gPendingContext = nil;
static __weak id gPendingProperties = nil;
static NSMutableArray *gPendingRequests;
static __weak id gActiveCallbackRequest = nil;
static __weak NSThread *gActiveCallbackThread = nil;
static NSString *gActiveCallbackToken;
static NSString *gHandlerInFlightToken;
static NSString *gToken;
static NSString *gVariant;
static BOOL gRequestedDelta = NO;
static BOOL gOmitValidatorsArmed = NO;
static BOOL gOmitValidatorsApplied = NO;
static BOOL gCustomWireOverrideApplied = NO;
static NSDictionary *gCustomWireConfiguration;
static NSTimeInterval gStartTime = 0;
static NSTimeInterval gLowerEnteredTime = 0;
static BOOL gLowerDeltaUpdate = NO;
static NSTimeInterval gNativeCompletionTime = 0;
static BOOL gTimeoutReported = NO;
static NSDictionary *gRequest;
static NSMutableArray<NSDictionary *> *gWireAttempts;
static NSDictionary *gDidSucceed;
static NSMutableArray<NSDictionary *> *gDidFailEvents;
static NSDictionary *gDecoded;
static NSMutableArray<NSDictionary *> *gHandlerAttempts;
static NSDictionary *gResult;
static NSMutableArray<NSDictionary *> *gEvents;
static WAGRABPropsABTLiveCompletion gCompletion;
static NSString *gBeforeFingerprint;

static void EnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSObject new];
        gEvents = [NSMutableArray array];
        gPendingRequests = [NSMutableArray array];
        gWireAttempts = [NSMutableArray array];
        gDidFailEvents = [NSMutableArray array];
        gHandlerAttempts = [NSMutableArray array];
        gResult = @{
            @"schema": @"watweaks_abprops_abt_live_service_v2",
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

static BOOL ObjectMethodMatches(id object, NSString *selectorName, const char *encoding) {
    if (!object || !selectorName.length || !encoding) return NO;
    return EncodingMatches(class_getInstanceMethod([object class], NSSelectorFromString(selectorName)), encoding);
}

static id ResolvePersonalProperties(id context) {
    id properties = CallObjectNoArg(context, @"abProperties");
    if (!ObjectMethodMatches(properties, @"configHash", "@16@0:8") ||
        !ObjectMethodMatches(properties, @"refreshID", "@16@0:8") ||
        !ObjectMethodMatches(properties, @"resetConfigHashToEmptyString", "v16@0:8")) return nil;
    return properties;
}

static BOOL SupportedVariant(NSString *variant) {
    return [variant isEqualToString:WAGRABPropsABTVariantRegularHash] ||
           [variant isEqualToString:WAGRABPropsABTVariantDeltaRefreshID] ||
           [variant isEqualToString:WAGRABPropsABTVariantFullEmptyHash] ||
           [variant isEqualToString:WAGRABPropsABTVariantFullNoValidators] ||
           [variant isEqualToString:WAGRABPropsABTVariantCustomWire];
}

static BOOL VariantUsesDelta(NSString *variant, NSDictionary *customConfiguration) {
    if ([variant isEqualToString:WAGRABPropsABTVariantCustomWire]) {
        return [customConfiguration[@"delta_update"] boolValue];
    }
    return [variant isEqualToString:WAGRABPropsABTVariantDeltaRefreshID];
}

static BOOL SupportedPolicy(NSString *policy) {
    return [@[@"native", @"nil", @"empty", @"zero", @"custom"] containsObject:policy ?: @""];
}

static NSDictionary *NormalizeCustomConfiguration(NSDictionary *configuration,
                                                   NSString **diagnostic) {
    if (![configuration isKindOfClass:NSDictionary.class]) {
        if (diagnostic) *diagnostic = @"custom ABT configuration is not a dictionary";
        return nil;
    }
    NSString *configPolicy = [configuration[@"config_hash_policy"] isKindOfClass:NSString.class]
        ? [configuration[@"config_hash_policy"] lowercaseString] : @"native";
    NSString *refreshPolicy = [configuration[@"refresh_id_policy"] isKindOfClass:NSString.class]
        ? [configuration[@"refresh_id_policy"] lowercaseString] : @"native";
    if (!SupportedPolicy(configPolicy) || !SupportedPolicy(refreshPolicy)) {
        if (diagnostic) *diagnostic = [NSString stringWithFormat:
            @"unsupported validator policy configHash=%@ refreshID=%@",
            configPolicy ?: @"?", refreshPolicy ?: @"?"];
        return nil;
    }
    id configValue = configuration[@"custom_config_hash"];
    id refreshValue = configuration[@"custom_refresh_id"];
    if ([configPolicy isEqualToString:@"custom"] &&
        ![configValue isKindOfClass:NSString.class]) {
        if (diagnostic) *diagnostic = @"config_hash_policy=custom requires custom_config_hash string";
        return nil;
    }
    if ([refreshPolicy isEqualToString:@"custom"] &&
        ![refreshValue isKindOfClass:NSString.class]) {
        if (diagnostic) *diagnostic = @"refresh_id_policy=custom requires custom_refresh_id string";
        return nil;
    }
    if ([configValue isKindOfClass:NSString.class] && [(NSString *)configValue length] > 256) {
        if (diagnostic) *diagnostic = @"custom_config_hash exceeds 256 characters";
        return nil;
    }
    if ([refreshValue isKindOfClass:NSString.class] && [(NSString *)refreshValue length] > 256) {
        if (diagnostic) *diagnostic = @"custom_refresh_id exceeds 256 characters";
        return nil;
    }
    NSTimeInterval timeout = [configuration[@"timeout_seconds"] doubleValue];
    if (timeout <= 0) timeout = 45.0;
    timeout = MAX(45.0, MIN(120.0, timeout));
    NSString *label = [configuration[@"label"] isKindOfClass:NSString.class]
        ? configuration[@"label"] : @"manual";
    if (label.length > 64) label = [label substringToIndex:64];
    return @{
        @"label": label ?: @"manual",
        @"delta_update": @([configuration[@"delta_update"] boolValue]),
        @"config_hash_policy": configPolicy,
        @"refresh_id_policy": refreshPolicy,
        @"custom_config_hash": [configValue isKindOfClass:NSString.class] ? configValue : @"",
        @"custom_refresh_id": [refreshValue isKindOfClass:NSString.class] ? refreshValue : @"",
        @"timeout_seconds": @(timeout)
    };
}

static id ValueForPolicy(NSString *policy, id nativeValue, NSString *customValue) {
    if ([policy isEqualToString:@"nil"]) return nil;
    if ([policy isEqualToString:@"empty"]) return @"";
    if ([policy isEqualToString:@"zero"]) return @"0";
    if ([policy isEqualToString:@"custom"]) return customValue ?: @"";
    return nativeValue;
}

static NSDictionary *BinaryEvidence(void) {
    return @{
        @"sharedmodules_sha256": @"f0edef076c68d7f1f872401d774789a2cb3f50be5c96773a2d8ed763ed3015a7",
        @"requestFreshABProps_thunk": @"0x003f55f8",
        @"request_manager_full_path": @"0x003e5bf8",
        @"request_builder": @"0x003f5820",
        @"request_initializer": @"0x003f58ec",
        @"query_enqueue_path": @"0x003f57b0",
        @"response_handler": @"0x003fee38",
        @"full_store_update_callsite": @"0x003ff0d0",
        @"delta_store_update_callsite": @"0x003ff0e0",
        @"WAProperties_propertiesStore_ivar": @"0x8",
        @"WAPropertiesStore_preferencesStore_ivar": @"0x8",
        @"WAPropertiesStore_namespace_ivar": @"0x20",
        @"WAPropertiesStore_propertiesType_ivar": @"0x30",
        @"WAPropertiesStore_groupJID_ivar": @"0x38",
        @"WAPropertiesStore_properties_ivar": @"0x60"
    };
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

static BOOL PendingContainsIdenticalRequest(id request) {
    for (id candidate in gPendingRequests) if (candidate == request) return YES;
    return NO;
}

static NSUInteger PendingRequestAttempt(id request) {
    NSUInteger index = 0;
    for (id candidate in gPendingRequests) {
        if (candidate == request) return index + 1;
        index++;
    }
    return 0;
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

static BOOL IsJSONNull(id value) {
    return value == nil || value == NSNull.null;
}

static id ExpectedJSONValueForPolicy(NSString *policy, id builderValue,
                                     NSString *customValue) {
    if ([policy isEqualToString:@"nil"]) return NSNull.null;
    if ([policy isEqualToString:@"empty"]) return @"";
    if ([policy isEqualToString:@"zero"]) return @"0";
    if ([policy isEqualToString:@"custom"]) return customValue ?: @"";
    return builderValue ?: NSNull.null;
}

static BOOL SameJSONArgument(id left, id right) {
    if (IsJSONNull(left) || IsJSONNull(right)) return IsJSONNull(left) && IsJSONNull(right);
    return [left isEqual:right];
}

static BOOL WireShapeMatchesVariant(NSString *variant,
                                    NSArray<NSDictionary *> *attempts,
                                    BOOL omitValidatorsApplied,
                                    NSDictionary *customConfiguration) {
    if (!attempts.count) return NO;
    for (NSDictionary *attempt in attempts) {
        id configHash = attempt[@"effective_config_hash"];
        id refreshID = attempt[@"effective_refresh_id"];
        NSString *override = [attempt[@"validator_override"] isKindOfClass:NSString.class]
            ? attempt[@"validator_override"] : @"";
        if ([variant isEqualToString:WAGRABPropsABTVariantRegularHash]) {
            if (!IsJSONNull(refreshID) || ![override isEqualToString:@"none"]) return NO;
        } else if ([variant isEqualToString:WAGRABPropsABTVariantDeltaRefreshID]) {
            if (!IsJSONNull(configHash) || IsJSONNull(refreshID) ||
                ![override isEqualToString:@"none"]) return NO;
        } else if ([variant isEqualToString:WAGRABPropsABTVariantFullNoValidators]) {
            if (!IsJSONNull(configHash) || !IsJSONNull(refreshID) ||
                ![override isEqualToString:@"omit_config_hash_and_refresh_id"]) return NO;
        } else if ([variant isEqualToString:WAGRABPropsABTVariantFullEmptyHash]) {
            if (![configHash isKindOfClass:NSString.class] || [(NSString *)configHash length] != 0 ||
                !IsJSONNull(refreshID) || ![override isEqualToString:@"none"]) return NO;
        } else if ([variant isEqualToString:WAGRABPropsABTVariantCustomWire]) {
            id expectedConfig = ExpectedJSONValueForPolicy(
                customConfiguration[@"config_hash_policy"], attempt[@"builder_config_hash"],
                customConfiguration[@"custom_config_hash"]);
            id expectedRefresh = ExpectedJSONValueForPolicy(
                customConfiguration[@"refresh_id_policy"], attempt[@"builder_refresh_id"],
                customConfiguration[@"custom_refresh_id"]);
            if (!SameJSONArgument(configHash, expectedConfig) ||
                !SameJSONArgument(refreshID, expectedRefresh) ||
                ![override hasPrefix:@"custom:"]) return NO;
        } else {
            return NO;
        }
    }
    if ([variant isEqualToString:WAGRABPropsABTVariantFullNoValidators]) {
        return omitValidatorsApplied;
    }
    return YES;
}

static NSDictionary *SnapshotSummary(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{ @"available": @NO };
    NSDictionary *metadata = snapshot.metadata ?: @{};
    NSMutableDictionary *out = [@{
        @"available": @YES,
        @"prop_count": @(snapshot.numericPropCount),
        @"fingerprint": snapshot.fingerprint ?: @"",
        @"source_kind": snapshot.sourceKind ?: @"unknown",
        @"store_class": snapshot.storeClassName ?: @"",
        @"store_namespace": snapshot.storeNamespace ?: @"",
        @"store_group_jid": snapshot.storeGroupJID ?: NSNull.null,
        @"store_properties_type": @(snapshot.storePropertiesType),
        @"store_identity": snapshot.payloadKey ?: @""
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

static NSDictionary *CompactHandlerRecord(NSDictionary *decoded) {
    if (![decoded isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *compact = [decoded mutableCopy];
    [compact removeObjectForKey:@"props"];
    [compact removeObjectForKey:@"sampling_weights"];
    return compact;
}

static NSDictionary *BuildFinalResult(void) {
    NSDictionary *request = nil, *didSucceed = nil, *decoded = nil;
    NSArray *wireAttempts = nil, *didFailEvents = nil, *handlerAttempts = nil;
    NSArray *events = nil;
    NSString *beforeFingerprint = nil, *token = nil, *variant = nil;
    id properties = nil;
    NSTimeInterval lowerTime = 0, completionTime = 0;
    BOOL lowerDeltaUpdate = NO;
    BOOL omitValidatorsApplied = NO;
    BOOL customWireOverrideApplied = NO;
    BOOL timeoutReported = NO;
    NSDictionary *customConfiguration = nil;
    @synchronized (gLock) {
        request = [gRequest copy] ?: @{};
        wireAttempts = [gWireAttempts copy] ?: @[];
        didSucceed = [gDidSucceed copy] ?: @{};
        didFailEvents = [gDidFailEvents copy] ?: @[];
        decoded = [gDecoded copy] ?: @{};
        handlerAttempts = [gHandlerAttempts copy] ?: @[];
        events = [gEvents copy] ?: @[];
        beforeFingerprint = [gBeforeFingerprint copy] ?: @"";
        token = [gToken copy] ?: @"";
        variant = [gVariant copy] ?: @"";
        properties = gPendingProperties;
        lowerTime = gLowerEnteredTime;
        lowerDeltaUpdate = gLowerDeltaUpdate;
        completionTime = gNativeCompletionTime;
        omitValidatorsApplied = gOmitValidatorsApplied;
        customWireOverrideApplied = gCustomWireOverrideApplied;
        timeoutReported = gTimeoutReported;
        customConfiguration = [gCustomWireConfiguration copy] ?: @{};
    }

    WAGRABPropsNativeSnapshot *after = WAGRABPropsReadNativeSnapshotForProperties(properties, NULL);
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
    // The native delta store selector is
    // -deltaUpdateWithNewProperties:refreshID:. It intentionally has no
    // encryptedRID argument, so a delta response must not be rejected merely
    // because that response-only value differs from the last full metadata.
    BOOL encryptedRIDPersistenceExpected = !delta;
    id handlerError = decoded[@"error"];
    BOOL handlerErrorPresent = handlerError && handlerError != NSNull.null;
    BOOL exactRequestSucceeded = didSucceed.count > 0;
    BOOL correlatedHandler = decoded.count > 0;
    BOOL nativeCompletionObserved = completionTime > 0;
    BOOL metadataMatches = hashMatch && refreshMatch &&
                           (!encryptedRIDPersistenceExpected || eridMatch);
    BOOL exactStore = [after.sourceKind isEqualToString:@"exact_native_wa_properties_store"];
    BOOL wireShapeMatches = WireShapeMatchesVariant(variant, wireAttempts,
                                                    omitValidatorsApplied,
                                                    customConfiguration);
    BOOL requestedDelta = VariantUsesDelta(variant, customConfiguration);
    BOOL nativeBranchMatches = lowerTime > 0 && lowerDeltaUpdate == requestedDelta;
    BOOL fullVariant = [variant isEqualToString:WAGRABPropsABTVariantFullNoValidators] ||
                       [variant isEqualToString:WAGRABPropsABTVariantFullEmptyHash];
    BOOL fullResponseConfirmed = !fullVariant || (!delta && wireCount > 0);
    id directHashValue = CallObjectNoArg(properties, @"configHash");
    NSString *directHash = [directHashValue isKindOfClass:NSString.class] ? directHashValue : nil;
    BOOL resetHashRefilled = ![variant isEqualToString:WAGRABPropsABTVariantFullEmptyHash] ||
                            directHash.length > 0;
    BOOL verified = nativeCompletionObserved && exactRequestSucceeded && correlatedHandler &&
                    !handlerErrorPresent && after != nil && exactStore && metadataMatches &&
                    nativeBranchMatches && wireShapeMatches && fullResponseConfirmed && resetHashRefilled;
    NSString *outcome = nil;
    if (verified) outcome = @"verified_native_response_applied";
    else if (!exactRequestSucceeded && didFailEvents.count) outcome = @"all_exact_request_attempts_failed";
    else if (!nativeCompletionObserved) outcome = @"native_completion_not_observed";
    else if (!correlatedHandler) outcome = @"native_completion_without_correlated_handler";
    else if (handlerErrorPresent) outcome = @"native_handler_reported_error";
    else if (!exactStore) outcome = @"exact_account_wa_properties_store_not_resolved";
    else if (!nativeBranchMatches) outcome = @"native_delta_branch_mismatch";
    else if (!wireShapeMatches) outcome = @"wire_shape_not_confirmed";
    else if (!fullResponseConfirmed) outcome = @"full_response_not_confirmed";
    else if (!resetHashRefilled) outcome = @"native_hash_not_refilled_after_full_response";
    else outcome = @"native_response_store_not_verified";
    NSString *effectiveSource = handlerErrorPresent ? @"native handler error; store state is not attributed to this request"
        : (wireCount == 0 ? @"WAPropertiesStore after successful no-change response"
        : (delta ? @"wire delta + WAPropertiesStore merged state" : @"wire full response + WAPropertiesStore confirmed state"));

    NSDictionary *effectiveDocument = after
        ? (WAGRABPropsNativeABTOnlyExportDocument(after) ?: @{}) : @{};
    NSDictionary *result = @{
        @"schema": @"watweaks_abprops_abt_live_service_v2",
        @"token": token,
        @"variant": variant,
        @"outcome": outcome,
        @"verified": @(verified),
        @"request": request,
        @"wire_attempts": wireAttempts,
        @"wire_shape_matches_variant": @(wireShapeMatches),
        @"one_shot_validator_override_applied": @(omitValidatorsApplied),
        @"custom_wire_override_applied": @(customWireOverrideApplied),
        @"custom_wire_configuration": customConfiguration,
        @"lower_request_entered": @(lowerTime > 0),
        @"lower_request_entered_time": @(lowerTime),
        @"lower_delta_update_observed": @(lowerDeltaUpdate),
        @"native_delta_branch_matches_variant": @(nativeBranchMatches),
        @"native_completion_observed": @(nativeCompletionObserved),
        @"native_completion_time": @(completionTime),
        @"timeout_reported_before_completion": @(timeoutReported),
        @"did_succeed_response": didSucceed,
        @"did_fail_events": didFailEvents,
        @"decoded_response": decoded,
        @"handler_attempts": handlerAttempts,
        @"wire_response_observed": @(exactRequestSucceeded),
        @"wire_prop_count": @(wireCount),
        @"effective_prop_count": @(after.numericPropCount),
        @"effective_source": effectiveSource,
        @"effective_snapshot": effectiveDocument,
        @"store_confirmation": @{
            @"available": @(after != nil),
            @"exact_account_store": @(exactStore),
            @"source_kind": after.sourceKind ?: @"unavailable",
            @"direct_config_hash": JSONSafe(directHashValue, 0),
            @"reset_hash_refilled": @(resetHashRefilled),
            @"fingerprint_changed": @(fingerprintChanged),
            @"config_hash_matches": @(hashMatch),
            @"refresh_id_matches": @(refreshMatch),
            @"encrypted_rid_matches": @(eridMatch),
            @"encrypted_rid_persistence_expected": @(encryptedRIDPersistenceExpected),
            @"metadata_matches": @(metadataMatches),
            @"after": SnapshotSummary(after)
        },
        @"binary_evidence": BinaryEvidence(),
        @"transaction_gate_before_release": WAGRABPropsABTTransactionGateDocument(),
        @"events": events
    };
    return result;
}


NSDictionary<NSString *, id> *WAGRABPropsABTAccountSnapshotDocument(
    id userContext, NSError **outError) {
    id context = userContext ?: WAGRCurrentUserContext();
    id properties = ResolvePersonalProperties(context);
    WAGRABPropsNativeSnapshot *snapshot =
        WAGRABPropsReadNativeSnapshotForProperties(properties, outError);
    if (!snapshot) return nil;
    NSDictionary *document = WAGRABPropsNativeABTOnlyExportDocument(snapshot);
    if (![document[@"source_kind"] isEqual:@"exact_native_wa_properties_store"]) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks.ABTLive" code:31
            userInfo:@{NSLocalizedDescriptionKey:
                @"Snapshot recusado porque não veio do WAPropertiesStore exato da conta."}];
        return nil;
    }
    return document;
}

BOOL WAGRABPropsABTVerifiedFullEmptyHashResult(
    NSDictionary<NSString *, id> *result, NSString **diagnostic) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSDictionary *document = [result[@"effective_snapshot"] isKindOfClass:NSDictionary.class]
        ? result[@"effective_snapshot"] : @{};
    NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class]
        ? document[@"entries"] : @[];
    NSDictionary *didSucceed = [result[@"did_succeed_response"] isKindOfClass:NSDictionary.class]
        ? result[@"did_succeed_response"] : @{};
    NSDictionary *decoded = [result[@"decoded_response"] isKindOfClass:NSDictionary.class]
        ? result[@"decoded_response"] : @{};
    NSArray *handlerAttempts = [result[@"handler_attempts"] isKindOfClass:NSArray.class]
        ? result[@"handler_attempts"] : @[];
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"store_confirmation"] : @{};
    NSUInteger wireCount = [result[@"wire_prop_count"] unsignedIntegerValue];
    NSUInteger effectiveCount = [result[@"effective_prop_count"] unsignedIntegerValue];
    NSUInteger documentCount = [document[@"prop_count"] unsignedIntegerValue];

    if (![result[@"variant"] isEqual:WAGRABPropsABTVariantFullEmptyHash])
        [missing addObject:@"variant != full_empty_hash"];
    if (![result[@"outcome"] isEqual:@"verified_native_response_applied"] ||
        ![result[@"verified"] boolValue])
        [missing addObject:@"native result not verified"];
    if (![result[@"wire_response_observed"] boolValue])
        [missing addObject:@"exact XMPP response not observed"];
    if (![result[@"native_completion_observed"] boolValue])
        [missing addObject:@"native completion missing"];
    if (![result[@"wire_shape_matches_variant"] boolValue])
        [missing addObject:@"wire shape was not empty-hash/full"];
    if (![didSucceed[@"request_class"] isEqual:@"XMPPRequestABProperties"] ||
        ![didSucceed[@"response_class"] isEqual:@"XMPPIQStanza"])
        [missing addObject:@"didSucceed XMPPIQStanza proof missing"];
    if (!handlerAttempts.count || ![decoded[@"correlated_request_attempt"] unsignedIntegerValue])
        [missing addObject:@"correlated native handler missing"];
    if (!decoded[@"delta_update"] || [decoded[@"delta_update"] boolValue])
        [missing addObject:@"handler was not confirmed as full"];
    if (!wireCount) [missing addObject:@"server response contained zero properties"];
    if (![store[@"available"] boolValue] || ![store[@"exact_account_store"] boolValue] ||
        ![store[@"metadata_matches"] boolValue])
        [missing addObject:@"exact account store did not match response"];
    if (![store[@"reset_hash_refilled"] boolValue])
        [missing addObject:@"configHash was not refilled by native store"];
    if (![document[@"source_kind"] isEqual:@"exact_native_wa_properties_store"])
        [missing addObject:@"snapshot did not come from exact WAPropertiesStore"];
    if (!document.count || !entries.count)
        [missing addObject:@"effective ABT snapshot missing"];
    if (wireCount != effectiveCount || wireCount != documentCount ||
        documentCount != entries.count)
        [missing addObject:@"wire/store/snapshot counts differ"];

    BOOL verified = missing.count == 0;
    if (diagnostic) {
        if (verified) {
            *diagnostic = [NSString stringWithFormat:
                @"server IQ -> full handler -> exact WAPropertiesStore verified: %@ · wire=%lu · snapshot=%lu",
                didSucceed[@"response_description"] ?: @"XMPPIQStanza",
                (unsigned long)wireCount, (unsigned long)entries.count];
        } else {
            *diagnostic = [NSString stringWithFormat:@"ABT fetch rejected: %@",
                [missing componentsJoinedByString:@"; "]];
        }
    }
    return verified;
}

static void Finish(NSString *expectedToken) {
    @synchronized (gLock) {
        if (!gPending || !expectedToken.length || ![gToken isEqualToString:expectedToken]) return;
    }
    WAGRABPropsABTLiveCompletion completion = nil;
    NSDictionary *provisional = BuildFinalResult();
    Event(@"explicit_transaction_finished", @{
        @"token": expectedToken,
        @"wire_prop_count": provisional[@"wire_prop_count"] ?: @0,
        @"effective_prop_count": provisional[@"effective_prop_count"] ?: @0,
        @"outcome": provisional[@"outcome"] ?: @"?"
    });
    NSDictionary *result = BuildFinalResult();
    @synchronized (gLock) {
        if (!gPending || ![gToken isEqualToString:expectedToken]) return;
        gResult = result;
        completion = [gCompletion copy];
        gCompletion = nil;
        gPending = NO;
        gDispatchArmed = NO;
        gPendingManager = nil;
        gPendingContext = nil;
        gPendingProperties = nil;
        [gPendingRequests removeAllObjects];
        gActiveCallbackRequest = nil;
        gActiveCallbackThread = nil;
        gActiveCallbackToken = nil;
        gHandlerInFlightToken = nil;
        gOmitValidatorsArmed = NO;
        gCustomWireOverrideApplied = NO;
        gCustomWireConfiguration = nil;
        gTimeoutReported = NO;
    }
    WAGRABPropsABTTransactionRelease(expectedToken);
    WAGRLogAppendF(@"[ABProps][ABTLive] variant=%@ wire=%@ effective=%@ verified=%@ outcome=%@",
                   result[@"variant"] ?: @"?",
                   result[@"wire_prop_count"] ?: @0,
                   result[@"effective_prop_count"] ?: @0,
                   [result[@"verified"] boolValue] ? @"YES" : @"NO",
                   result[@"outcome"] ?: @"?");
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
}

static void FinishWhenHandlerSettled(NSString *expectedToken) {
    BOOL current = NO, handlerInFlight = NO;
    @synchronized (gLock) {
        current = gPending && [gToken isEqualToString:expectedToken];
        handlerInFlight = current && [gHandlerInFlightToken isEqualToString:expectedToken];
    }
    if (!current) return;
    NSTimeInterval delay = handlerInFlight ? 0.10 : 0.30;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (handlerInFlight) FinishWhenHandlerSettled(expectedToken);
        else Finish(expectedToken);
    });
}

static void LowerHook(id self, SEL _cmd, id groupJID, BOOL deltaUpdate, id completion) {
    BOOL belongs = NO;
    NSString *transactionToken = nil;
    @synchronized (gLock) {
        belongs = gPending && gDispatchArmed && self == gPendingManager;
        if (belongs) {
            gLowerEnteredTime = Now();
            gLowerDeltaUpdate = deltaUpdate;
            transactionToken = [gToken copy];
        }
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
        BOOL current = NO, afterReportedTimeout = NO;
        @synchronized (gLock) {
            current = gPending && [gToken isEqualToString:transactionToken];
            if (current) {
                afterReportedTimeout = gTimeoutReported;
                gNativeCompletionTime = Now();
            }
        }
        if (current) {
            Event(@"explicit_native_completion", @{
                @"token": transactionToken ?: @"",
                @"after_reported_timeout": @(afterReportedTimeout)
            });
        } else {
            WAGRLogAppendF(@"[ABProps][ABTLive] late completion no longer owns result token=%@",
                           transactionToken ?: @"?");
        }
        if (originalCompletion) originalCompletion();
        if (current) {
            FinishWhenHandlerSettled(transactionToken);
        } else {
            // Safe no-op unless an older timeout path still owns the gate.
            WAGRABPropsABTTransactionRelease(transactionToken);
        }
    };
    if (gOriginalLower) gOriginalLower(self, _cmd, groupJID, deltaUpdate, wrappedCompletion);
}

static id RequestInitHook(id self, SEL _cmd, id userContext, id groupJID,
                          id configHash, id refreshID, id completion) {
    BOOL candidate = NO;
    BOOL omitValidators = NO;
    NSString *variant = nil;
    NSDictionary *customConfiguration = nil;
    NSUInteger attemptNumber = 0;
    @synchronized (gLock) {
        BOOL expectedBuilderShape = gRequestedDelta
            ? (configHash == nil && refreshID != nil)
            : (refreshID == nil);
        candidate = gPending && gLowerEnteredTime > 0 &&
                    userContext == gPendingContext && !groupJID && expectedBuilderShape;
        if (candidate) {
            omitValidators = gOmitValidatorsArmed;
            variant = [gVariant copy] ?: @"";
            customConfiguration = [gCustomWireConfiguration copy] ?: @{};
            attemptNumber = gWireAttempts.count + 1;
        }
    }

    id originalConfigHash = configHash;
    id originalRefreshID = refreshID;
    BOOL customWire = candidate && [variant isEqualToString:WAGRABPropsABTVariantCustomWire];
    BOOL customOverrideApplied = NO;
    NSString *overrideDescription = @"none";
    if (candidate && omitValidators) {
        configHash = nil;
        refreshID = nil;
        overrideDescription = @"omit_config_hash_and_refresh_id";
    } else if (customWire) {
        NSString *configPolicy = customConfiguration[@"config_hash_policy"] ?: @"native";
        NSString *refreshPolicy = customConfiguration[@"refresh_id_policy"] ?: @"native";
        configHash = ValueForPolicy(configPolicy, configHash,
                                    customConfiguration[@"custom_config_hash"]);
        refreshID = ValueForPolicy(refreshPolicy, refreshID,
                                   customConfiguration[@"custom_refresh_id"]);
        customOverrideApplied = ![configPolicy isEqualToString:@"native"] ||
                                ![refreshPolicy isEqualToString:@"native"];
        overrideDescription = [NSString stringWithFormat:@"custom:%@/%@",
                               configPolicy, refreshPolicy];
    }

    id result = gOriginalRequestInit
        ? gOriginalRequestInit(self, _cmd, userContext, groupJID, configHash, refreshID, completion)
        : nil;

    if (candidate) {
        NSDictionary *wire = @{
            @"request_class": ClassName(result ?: self),
            @"initializer": kRequestInitSelector,
            @"initializer_encoding": Encoding([self class], kRequestInitSelector),
            @"group_jid": JSONSafe(groupJID, 0),
            @"builder_config_hash": JSONSafe(originalConfigHash, 0),
            @"builder_refresh_id": JSONSafe(originalRefreshID, 0),
            @"effective_config_hash": JSONSafe(configHash, 0),
            @"effective_refresh_id": JSONSafe(refreshID, 0),
            @"validator_override": overrideDescription,
            @"variant": variant ?: @"",
            @"attempt": @(attemptNumber)
        };
        @synchronized (gLock) {
            if (result) [gPendingRequests addObject:result];
            [gWireAttempts addObject:wire];
            gOmitValidatorsApplied = gOmitValidatorsApplied || omitValidators;
            gCustomWireOverrideApplied = gCustomWireOverrideApplied || customOverrideApplied;
        }
        Event(@"exact_request_initialized", @{
            @"request_class": ClassName(result ?: self),
            @"attempt": @(attemptNumber),
            @"config_hash_present": @(configHash != nil),
            @"refresh_id_present": @(refreshID != nil),
            @"validator_override_applied": @(omitValidators || customOverrideApplied),
            @"validator_override": overrideDescription
        });
    }
    return result;
}

static void DidSucceedHook(id self, SEL _cmd, id response) {
    BOOL candidate = NO;
    NSString *transactionToken = nil;
    NSUInteger attempt = 0;
    @synchronized (gLock) {
        candidate = gPending && PendingContainsIdenticalRequest(self) &&
                    gLowerEnteredTime > 0 && gNativeCompletionTime == 0;
        if (candidate) {
            transactionToken = [gToken copy];
            attempt = PendingRequestAttempt(self);
            gActiveCallbackRequest = self;
            gActiveCallbackThread = NSThread.currentThread;
            gActiveCallbackToken = transactionToken;
        }
    }
    if (candidate) {
        NSString *description = nil;
        @try { description = [response description]; } @catch (__unused NSException *exception) {}
        if (description.length > 1024) description = [description substringToIndex:1024];
        NSDictionary *record = @{
            @"time": @(Now()),
            @"token": transactionToken ?: @"",
            @"attempt": @(attempt),
            @"request_class": ClassName(self),
            @"response_class": ClassName(response),
            @"response_description": description ?: @""
        };
        @synchronized (gLock) { gDidSucceed = record; }
        Event(@"explicit_did_succeed_candidate", record);
    }
    @try {
        if (gOriginalDidSucceed) gOriginalDidSucceed(self, _cmd, response);
    } @finally {
        if (candidate) {
            @synchronized (gLock) {
                if (gActiveCallbackRequest == self &&
                    [gActiveCallbackToken isEqualToString:transactionToken] &&
                    gActiveCallbackThread == NSThread.currentThread) {
                    gActiveCallbackRequest = nil;
                    gActiveCallbackThread = nil;
                    gActiveCallbackToken = nil;
                }
            }
        }
    }
}

static void DidFailHook(id self, SEL _cmd, id error) {
    BOOL candidate = NO;
    NSString *transactionToken = nil;
    NSUInteger attempt = 0;
    @synchronized (gLock) {
        candidate = gPending && PendingContainsIdenticalRequest(self) &&
                    gLowerEnteredTime > 0 && gNativeCompletionTime == 0;
        if (candidate) {
            transactionToken = [gToken copy];
            attempt = PendingRequestAttempt(self);
            gActiveCallbackRequest = self;
            gActiveCallbackThread = NSThread.currentThread;
            gActiveCallbackToken = transactionToken;
        }
    }
    if (candidate) {
        NSDictionary *record = @{
            @"time": @(Now()),
            @"token": transactionToken ?: @"",
            @"attempt": @(attempt),
            @"request_class": ClassName(self),
            @"error": JSONSafe(error, 0)
        };
        @synchronized (gLock) { [gDidFailEvents addObject:record]; }
        Event(@"exact_request_failed", record);
    }
    @try {
        if (gOriginalDidFail) gOriginalDidFail(self, _cmd, error);
    } @finally {
        if (candidate) {
            @synchronized (gLock) {
                if (gActiveCallbackRequest == self &&
                    [gActiveCallbackToken isEqualToString:transactionToken] &&
                    gActiveCallbackThread == NSThread.currentThread) {
                    gActiveCallbackRequest = nil;
                    gActiveCallbackThread = nil;
                    gActiveCallbackToken = nil;
                }
            }
        }
    }
}

static void HandleHook(id self, SEL _cmd,
                       id groupJID, id error, id props, id samplingWeights,
                       int protocolVersion, id configKey, id configHash,
                       int64_t refreshInterval, id refreshID, id encryptedRID,
                       BOOL isDeltaUpdate, int64_t attemptIndex, int64_t maxAttempts,
                       id attemptCompletion) {
    BOOL candidate = NO;
    NSUInteger correlatedAttempt = 0;
    NSString *transactionToken = nil;
    @synchronized (gLock) {
        candidate = gPending && self == gPendingManager && !groupJID &&
                    gLowerEnteredTime > 0 &&
                    gActiveCallbackRequest != nil &&
                    gActiveCallbackThread == NSThread.currentThread &&
                    [gActiveCallbackToken isEqualToString:gToken] &&
                    PendingContainsIdenticalRequest(gActiveCallbackRequest);
        if (candidate) {
            correlatedAttempt = PendingRequestAttempt(gActiveCallbackRequest);
            transactionToken = [gToken copy];
            gHandlerInFlightToken = transactionToken;
        }
    }

    @try {
        if (gOriginalHandle) {
            gOriginalHandle(self, _cmd, groupJID, error, props, samplingWeights,
                            protocolVersion, configKey, configHash, refreshInterval,
                            refreshID, encryptedRID, isDeltaUpdate, attemptIndex,
                            maxAttempts, attemptCompletion);
        }
        if (!candidate) return;

        NSDictionary *decoded = @{
            @"time": @(Now()),
            @"token": transactionToken ?: @"",
            @"correlated_request_attempt": @(correlatedAttempt),
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
        BOOL stillCurrent = NO;
        @synchronized (gLock) {
            stillCurrent = gPending && [gToken isEqualToString:transactionToken];
            if (stillCurrent) {
                gDecoded = decoded;
                [gHandlerAttempts addObject:CompactHandlerRecord(decoded)];
            }
        }
        if (stillCurrent) {
            Event(@"explicit_decoded_handler_candidate", @{
                @"prop_count": @(Count(props)),
                @"sampling_count": @(Count(samplingWeights)),
                @"correlated_request_attempt": @(correlatedAttempt),
                @"delta_update": @(isDeltaUpdate),
                @"has_error": @(error != nil)
            });
        }
    } @finally {
        if (candidate) {
            @synchronized (gLock) {
                if ([gHandlerInFlightToken isEqualToString:transactionToken]) {
                    gHandlerInFlightToken = nil;
                }
            }
        }
    }
}

static BOOL InstallHooks(void) {
    EnsureState();
    Class managerClass = NSClassFromString(kManagerClass) ?: objc_getClass(kManagerClass.UTF8String);
    Class requestClass = NSClassFromString(kRequestClass) ?: objc_getClass(kRequestClass.UTF8String);
    Method lower = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kLowerSelector)) : NULL;
    Method requestInit = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kRequestInitSelector)) : NULL;
    Method did = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kDidSucceedSelector)) : NULL;
    Method failed = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kDidFailSelector)) : NULL;
    Method handle = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kHandleSelector)) : NULL;
    if (!EncodingMatches(lower, kLowerEncoding) ||
        !EncodingMatches(requestInit, kRequestInitEncoding) ||
        !EncodingMatches(did, kDidSucceedEncoding) ||
        !EncodingMatches(failed, kDidFailEncoding) ||
        !EncodingMatches(handle, kHandleEncoding)) return NO;

    if (gInstalled) {
        return method_getImplementation(lower) == (IMP)LowerHook &&
               method_getImplementation(requestInit) == (IMP)RequestInitHook &&
               method_getImplementation(did) == (IMP)DidSucceedHook &&
               method_getImplementation(failed) == (IMP)DidFailHook &&
               method_getImplementation(handle) == (IMP)HandleHook;
    }

    IMP lowerCurrent = method_getImplementation(lower);
    IMP requestInitCurrent = method_getImplementation(requestInit);
    IMP didCurrent = method_getImplementation(did);
    IMP failedCurrent = method_getImplementation(failed);
    IMP handleCurrent = method_getImplementation(handle);
    if (!lowerCurrent || !requestInitCurrent || !didCurrent || !failedCurrent || !handleCurrent) return NO;
    gOriginalLower = (void (*)(id, SEL, id, BOOL, id))lowerCurrent;
    gOriginalRequestInit = (id (*)(id, SEL, id, id, id, id, id))requestInitCurrent;
    gOriginalDidSucceed = (void (*)(id, SEL, id))didCurrent;
    gOriginalDidFail = (void (*)(id, SEL, id))failedCurrent;
    gOriginalHandle = (void (*)(id, SEL, id, id, id, id, int, id, id, int64_t, id, id, BOOL, int64_t, int64_t, id))handleCurrent;
    method_setImplementation(lower, (IMP)LowerHook);
    method_setImplementation(requestInit, (IMP)RequestInitHook);
    method_setImplementation(did, (IMP)DidSucceedHook);
    method_setImplementation(failed, (IMP)DidFailHook);
    method_setImplementation(handle, (IMP)HandleHook);
    gInstalled = YES;
    Event(@"correlation_hooks_installed", @{
        @"lower_encoding": Encoding(managerClass, kLowerSelector),
        @"request_initializer_encoding": Encoding(requestClass, kRequestInitSelector),
        @"did_succeed_encoding": Encoding(requestClass, kDidSucceedSelector),
        @"did_fail_encoding": Encoding(requestClass, kDidFailSelector),
        @"handler_encoding": Encoding(managerClass, kHandleSelector)
    });
    return YES;
}

static void AbortTransaction(NSString *token, NSString *outcome, NSString *text) {
    NSString *variant = nil;
    @synchronized (gLock) {
        if (![gToken isEqualToString:token]) return;
        variant = [gVariant copy];
        gResult = @{
            @"schema": @"watweaks_abprops_abt_live_service_v2",
            @"token": token ?: @"",
            @"variant": gVariant ?: @"",
            @"outcome": outcome ?: @"dispatch_aborted",
            @"verified": @NO,
            @"diagnostic": text ?: @"",
            @"request": gRequest ?: @{},
            @"wire_attempts": [gWireAttempts copy] ?: @[],
            @"handler_attempts": [gHandlerAttempts copy] ?: @[],
            @"custom_wire_override_applied": @(gCustomWireOverrideApplied),
            @"custom_wire_configuration": gCustomWireConfiguration ?: @{},
            @"binary_evidence": BinaryEvidence(),
            @"events": [gEvents copy] ?: @[]
        };
        gCompletion = nil;
        gPending = NO;
        gDispatchArmed = NO;
        gPendingManager = nil;
        gPendingContext = nil;
        gPendingProperties = nil;
        [gPendingRequests removeAllObjects];
        gActiveCallbackRequest = nil;
        gActiveCallbackThread = nil;
        gActiveCallbackToken = nil;
        gHandlerInFlightToken = nil;
        gOmitValidatorsArmed = NO;
        gCustomWireOverrideApplied = NO;
        gCustomWireConfiguration = nil;
        gTimeoutReported = NO;
    }
    WAGRABPropsABTTransactionRelease(token);
    WAGRLogAppendF(@"[ABProps][ABTLive] variant=%@ aborted outcome=%@ diagnostic=%@",
                   variant ?: @"?", outcome ?: @"?", text ?: @"");
}

static BOOL WAGRABPropsABTLiveFetchVariantInternal(NSString *variant,
                                                   id userContext,
                                                   NSString *gateOwnerToken,
                                                   NSDictionary *customConfiguration,
                                                   WAGRABPropsABTLiveCompletion completion,
                                                   NSString **diagnostic) {
    EnsureState();
    if (!SupportedVariant(variant)) {
        NSString *text = [NSString stringWithFormat:@"unsupported ABT lab variant: %@", variant ?: @"nil"];
        if (diagnostic) *diagnostic = text;
        return NO;
    }
    if ([variant isEqualToString:WAGRABPropsABTVariantCustomWire]) {
        NSString *normalizationDiagnostic = nil;
        NSDictionary *normalized = NormalizeCustomConfiguration(customConfiguration ?: @{},
                                                                 &normalizationDiagnostic);
        if (!normalized) {
            if (diagnostic) *diagnostic = normalizationDiagnostic ?: @"invalid custom ABT configuration";
            return NO;
        }
        customConfiguration = normalized;
    }
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
    id properties = ResolvePersonalProperties(context);
    if (!properties) {
        NSString *text = @"exact userContext.abProperties route or validator ABI is unavailable";
        if (diagnostic) *diagnostic = text;
        return NO;
    }
    Method top = class_getInstanceMethod([manager class], NSSelectorFromString(kTopSelector));
    if (!EncodingMatches(top, kTopEncoding)) {
        NSString *text = [NSString stringWithFormat:@"requestFreshABProps ABI mismatch: %@", Encoding([manager class], kTopSelector)];
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    WAGRABPropsNativeSnapshot *before = WAGRABPropsReadNativeSnapshotForProperties(properties, NULL);
    id beforeConfigHash = CallObjectNoArg(properties, @"configHash");
    id beforeRefreshID = CallObjectNoArg(properties, @"refreshID");
    NSString *token = NSUUID.UUID.UUIDString;
    customConfiguration = [customConfiguration copy] ?: @{};
    BOOL deltaUpdate = VariantUsesDelta(variant, customConfiguration);
    NSTimeInterval timeoutSeconds = [variant isEqualToString:WAGRABPropsABTVariantCustomWire]
        ? [customConfiguration[@"timeout_seconds"] doubleValue] : 45.0;
    NSString *gateDiagnostic = nil;
    BOOL gateAcquired = gateOwnerToken.length
        ? WAGRABPropsABTTransactionAcquireWithin(@"runtime_lab_variant", token,
                                                  gateOwnerToken, &gateDiagnostic)
        : WAGRABPropsABTTransactionAcquire(@"runtime_lab_variant", token,
                                            &gateDiagnostic);
    if (!gateAcquired) {
        if (diagnostic) *diagnostic = gateDiagnostic ?: @"another ABT transaction is active";
        return NO;
    }
    BOOL correlationBusy = NO;
    @synchronized (gLock) {
        correlationBusy = gPending;
        if (!correlationBusy) {
            gPending = YES;
            gDispatchArmed = YES;
            gPendingManager = manager;
            gPendingContext = context;
            gPendingProperties = properties;
            [gPendingRequests removeAllObjects];
            gActiveCallbackRequest = nil;
            gActiveCallbackThread = nil;
            gActiveCallbackToken = nil;
            gHandlerInFlightToken = nil;
            gToken = token;
            gVariant = [variant copy];
            gRequestedDelta = deltaUpdate;
            gOmitValidatorsArmed = [variant isEqualToString:WAGRABPropsABTVariantFullNoValidators];
            gOmitValidatorsApplied = NO;
            gCustomWireOverrideApplied = NO;
            gCustomWireConfiguration = [customConfiguration copy];
            gStartTime = Now();
            gLowerEnteredTime = 0;
            gLowerDeltaUpdate = NO;
            gNativeCompletionTime = 0;
            gTimeoutReported = NO;
            gDidSucceed = nil;
            [gDidFailEvents removeAllObjects];
            gDecoded = nil;
            [gHandlerAttempts removeAllObjects];
            [gWireAttempts removeAllObjects];
            gRequest = nil;
            gBeforeFingerprint = before.fingerprint ?: @"";
            gCompletion = [completion copy];
            [gEvents removeAllObjects];
        }
    }
    if (correlationBusy) {
        WAGRABPropsABTTransactionRelease(token);
        if (diagnostic) *diagnostic = @"another correlated ABT transaction is still pending";
        return NO;
    }

    id afterResetHash = beforeConfigHash;
    BOOL resetConfirmed = NO;
    if ([variant isEqualToString:WAGRABPropsABTVariantFullEmptyHash]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(properties,
                NSSelectorFromString(@"resetConfigHashToEmptyString"));
        } @catch (NSException *exception) {
            NSString *text = [NSString stringWithFormat:@"resetConfigHashToEmptyString threw %@",
                              exception.reason ?: @"exception"];
            AbortTransaction(token, @"native_hash_reset_threw", text);
            if (diagnostic) *diagnostic = text;
            return NO;
        }
        afterResetHash = CallObjectNoArg(properties, @"configHash");
        resetConfirmed = [afterResetHash isKindOfClass:NSString.class] &&
            [(NSString *)afterResetHash length] == 0;
        if (!resetConfirmed) {
            NSString *text = [NSString stringWithFormat:
                @"native hash reset did not produce the empty-string wire shape (class=%@); use full_no_validators for the nil/nil form",
                ClassName(afterResetHash)];
            AbortTransaction(token, @"native_hash_reset_not_confirmed", text);
            if (diagnostic) *diagnostic = text;
            return NO;
        }
    }

    @synchronized (gLock) {
        gRequest = @{
            @"token": token,
            @"time": @(gStartTime),
            @"variant": variant,
            @"namespace": @"abt",
            @"context_class": ClassName(context),
            @"manager_class": ClassName(manager),
            @"properties_class": ClassName(properties),
            @"top_selector": kTopSelector,
            @"top_encoding": Encoding([manager class], kTopSelector),
            @"lower_selector": kLowerSelector,
            @"lower_encoding": Encoding([manager class], kLowerSelector),
            @"request_initializer": kRequestInitSelector,
            @"request_initializer_encoding": Encoding(NSClassFromString(kRequestClass), kRequestInitSelector),
            @"delta_update_requested": @(deltaUpdate),
            @"before_config_hash": JSONSafe(beforeConfigHash, 0),
            @"before_refresh_id": JSONSafe(beforeRefreshID, 0),
            @"native_hash_reset_requested": @([variant isEqualToString:WAGRABPropsABTVariantFullEmptyHash]),
            @"native_hash_reset_confirmed": @(resetConfirmed),
            @"after_reset_config_hash": JSONSafe(afterResetHash, 0),
            @"one_shot_omit_validators_armed": @(gOmitValidatorsArmed),
            @"custom_wire_configuration": customConfiguration,
            @"timeout_seconds": @(timeoutSeconds),
            @"before": SnapshotSummary(before)
        };
        gResult = @{
            @"schema": @"watweaks_abprops_abt_live_service_v2",
            @"token": token,
            @"variant": variant,
            @"outcome": @"pending",
            @"verified": @NO
        };
    }

    Event(@"explicit_transaction_started", @{
        @"token": token,
        @"variant": variant,
        @"delta_update": @(deltaUpdate),
        @"native_hash_reset_confirmed": @(resetConfirmed)
    });
    void (^topCompletion)(void) = ^{ Event(@"explicit_top_completion_forwarded", @{ @"token": token }); };
    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager,
            NSSelectorFromString(kTopSelector), deltaUpdate, topCompletion);
    } @catch (NSException *exception) {
        NSString *text = [NSString stringWithFormat:@"native ABT request threw %@", exception.reason ?: @"exception"];
        AbortTransaction(token, @"native_request_threw", text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }
    @synchronized (gLock) { gDispatchArmed = NO; }

    BOOL lowerEntered = NO;
    @synchronized (gLock) { lowerEntered = gLowerEnteredTime > 0; }
    if (!lowerEntered) {
        NSString *text = @"requestFreshABProps returned without entering the exact lower native request method";
        AbortTransaction(token, @"lower_request_not_entered", text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    NSString *text = [NSString stringWithFormat:
        @"ABT %@ %@ entered; awaiting exact request initializer, response handler and native completion",
        variant, token];
    if (diagnostic) *diagnostic = text;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL timeout = NO;
        @synchronized (gLock) {
            timeout = gPending && [gToken isEqualToString:token] &&
                      gNativeCompletionTime == 0 && !gTimeoutReported;
        }
        if (!timeout) return;
        Event(@"explicit_transaction_timeout", @{ @"token": token });
        NSDictionary *fallback = BuildFinalResult();
        WAGRABPropsABTLiveCompletion callback = nil;
        NSDictionary *timeoutResult = nil;
        @synchronized (gLock) {
            if (!gPending || ![gToken isEqualToString:token] ||
                gNativeCompletionTime > 0 || gTimeoutReported) return;
            NSMutableDictionary *mutable = [fallback mutableCopy];
            mutable[@"outcome"] = @"timeout_waiting_exact_native_completion";
            mutable[@"gate_quarantined_until_native_completion"] = @YES;
            mutable[@"transaction_remains_correlated"] = @YES;
            mutable[@"timeout_reported_time"] = @(Now());
            gTimeoutReported = YES;
            gResult = mutable;
            timeoutResult = [mutable copy];
            callback = [gCompletion copy];
            gCompletion = nil;
        }
        WAGRLogAppendF(@"[ABProps][ABTLive] variant=%@ timed out token=%@ attempts=%lu; gate quarantined until native completion",
                       timeoutResult[@"variant"] ?: @"?", token,
                       (unsigned long)[timeoutResult[@"wire_attempts"] count]);
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(timeoutResult); });
    });
    return YES;
}

BOOL WAGRABPropsABTLiveFetchVariant(NSString *variant,
                                    id userContext,
                                    WAGRABPropsABTLiveCompletion completion,
                                    NSString **diagnostic) {
    return WAGRABPropsABTLiveFetchVariantInternal(variant, userContext, nil,
                                                   nil, completion, diagnostic);
}

BOOL WAGRABPropsABTLiveFetchVariantWithinTransaction(
    NSString *variant,
    id userContext,
    NSString *ownerToken,
    WAGRABPropsABTLiveCompletion completion,
    NSString **diagnostic) {
    if (!ownerToken.length) {
        if (diagnostic) *diagnostic = @"ABT matrix owner token is empty";
        return NO;
    }
    return WAGRABPropsABTLiveFetchVariantInternal(variant, userContext, ownerToken,
                                                   nil, completion, diagnostic);
}

BOOL WAGRABPropsABTLiveFetchCustom(
    NSDictionary<NSString *, id> *configuration,
    id userContext,
    WAGRABPropsABTLiveCompletion completion,
    NSString **diagnostic) {
    NSString *normalizationDiagnostic = nil;
    NSDictionary *normalized = NormalizeCustomConfiguration(configuration,
                                                             &normalizationDiagnostic);
    if (!normalized) {
        if (diagnostic) *diagnostic = normalizationDiagnostic ?: @"invalid custom ABT configuration";
        return NO;
    }
    return WAGRABPropsABTLiveFetchVariantInternal(WAGRABPropsABTVariantCustomWire,
                                                   userContext, nil, normalized,
                                                   completion, diagnostic);
}

BOOL WAGRABPropsABTLiveFetch(id userContext,
                             WAGRABPropsABTLiveCompletion completion,
                             NSString **diagnostic) {
    return WAGRABPropsABTLiveFetchVariant(WAGRABPropsABTVariantRegularHash,
                                          userContext, completion, diagnostic);
}

NSDictionary<NSString *, id> *WAGRABPropsABTLiveServiceDocument(void) {
    EnsureState();
    @synchronized (gLock) {
        if (gPending) {
            NSMutableDictionary *pending = [gResult mutableCopy] ?: [NSMutableDictionary dictionary];
            pending[@"schema"] = @"watweaks_abprops_abt_live_service_v2";
            pending[@"outcome"] = gTimeoutReported
                ? @"awaiting_late_native_completion_after_timeout" : @"pending";
            pending[@"timeout_reported"] = @(gTimeoutReported);
            pending[@"gate_quarantined_until_native_completion"] = @(gTimeoutReported);
            pending[@"variant"] = gVariant ?: @"";
            pending[@"request"] = gRequest ?: @{};
            pending[@"wire_attempts"] = [gWireAttempts copy] ?: @[];
            pending[@"lower_request_entered"] = @(gLowerEnteredTime > 0);
            pending[@"lower_delta_update_observed"] = @(gLowerDeltaUpdate);
            pending[@"did_succeed_response"] = gDidSucceed ?: @{};
            pending[@"did_fail_events"] = [gDidFailEvents copy] ?: @[];
            pending[@"decoded_response"] = gDecoded ?: @{};
            pending[@"handler_attempts"] = [gHandlerAttempts copy] ?: @[];
            pending[@"binary_evidence"] = BinaryEvidence();
            pending[@"events"] = [gEvents copy] ?: @[];
            return pending;
        }
        return [gResult copy] ?: @{};
    }
}

NSDictionary<NSString *, id> *WAGRABPropsABTLiveCapabilityDocument(id userContext) {
    EnsureState();
    BOOL installed = NO, pending = NO, timeoutReported = NO;
    @synchronized (gLock) {
        installed = gInstalled;
        pending = gPending;
        timeoutReported = gTimeoutReported;
    }
    id context = userContext ?: WAGRCurrentUserContext();
    id manager = ResolveManager(context);
    id properties = ResolvePersonalProperties(context);
    Class managerClass = manager ? [manager class]
        : (NSClassFromString(kManagerClass) ?: objc_getClass(kManagerClass.UTF8String));
    Class requestClass = NSClassFromString(kRequestClass) ?: objc_getClass(kRequestClass.UTF8String);

    Method top = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kTopSelector)) : NULL;
    Method lower = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kLowerSelector)) : NULL;
    Method requestInit = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kRequestInitSelector)) : NULL;
    Method didSucceed = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kDidSucceedSelector)) : NULL;
    Method didFail = requestClass ? class_getInstanceMethod(requestClass, NSSelectorFromString(kDidFailSelector)) : NULL;
    Method handler = managerClass ? class_getInstanceMethod(managerClass, NSSelectorFromString(kHandleSelector)) : NULL;

    BOOL topOK = EncodingMatches(top, kTopEncoding);
    BOOL lowerOK = EncodingMatches(lower, kLowerEncoding);
    BOOL initOK = EncodingMatches(requestInit, kRequestInitEncoding);
    BOOL didOK = EncodingMatches(didSucceed, kDidSucceedEncoding);
    BOOL failOK = EncodingMatches(didFail, kDidFailEncoding);
    BOOL handlerOK = EncodingMatches(handler, kHandleEncoding);
    BOOL coreAvailable = context && manager && properties && topOK && lowerOK &&
                         initOK && didOK && failOK && handlerOK;
    BOOL hooksActive = installed &&
        method_getImplementation(lower) == (IMP)LowerHook &&
        method_getImplementation(requestInit) == (IMP)RequestInitHook &&
        method_getImplementation(didSucceed) == (IMP)DidSucceedHook &&
        method_getImplementation(didFail) == (IMP)DidFailHook &&
        method_getImplementation(handler) == (IMP)HandleHook;
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshotForProperties(properties, NULL);

    NSArray *variants = @[
        @{
            @"id": WAGRABPropsABTVariantRegularHash,
            @"title": @"Regular · config hash atual",
            @"wire": @"configHash=current, refreshID=nil",
            @"delta_update": @NO,
            @"state_mutation": @"none",
            @"available": @(coreAvailable)
        },
        @{
            @"id": WAGRABPropsABTVariantDeltaRefreshID,
            @"title": @"Delta · refresh ID",
            @"wire": @"configHash=nil, refreshID=current-or-0",
            @"delta_update": @YES,
            @"state_mutation": @"none",
            @"available": @(coreAvailable)
        },
        @{
            @"id": WAGRABPropsABTVariantFullEmptyHash,
            @"title": @"Full · hash vazio nativo",
            @"wire": @"configHash=empty-string, refreshID=nil",
            @"delta_update": @NO,
            @"state_mutation": @"WAProperties.resetConfigHashToEmptyString",
            @"available": @(coreAvailable)
        },
        @{
            @"id": WAGRABPropsABTVariantFullNoValidators,
            @"title": @"Full cold · sem validadores",
            @"wire": @"configHash=nil, refreshID=nil",
            @"delta_update": @NO,
            @"state_mutation": @"transaction-scoped initializer arguments only",
            @"instrumentation_required": @YES,
            @"available": @(coreAvailable && initOK)
        },
        @{
            @"id": WAGRABPropsABTVariantCustomWire,
            @"title": @"Wire custom em runtime",
            @"wire": @"deltaUpdate + configHash/refreshID policies selected by user",
            @"state_mutation": @"transaction-scoped initializer arguments only",
            @"instrumentation_required": @YES,
            @"available": @(coreAvailable && initOK)
        }
    ];

    return @{
        @"schema": @"watweaks_abprops_abt_capabilities_v1",
        @"scope": @"ABProps ABT only; MobileConfig files are a separate pipeline",
        @"available": @(coreAvailable),
        @"pending": @(pending),
        @"timeout_reported_awaiting_completion": @(timeoutReported),
        @"context": @{
            @"resolved": @(context != nil),
            @"class": ClassName(context),
            @"manager_resolved": @(manager != nil),
            @"manager_class": ClassName(manager),
            @"properties_resolved": @(properties != nil),
            @"properties_class": ClassName(properties),
            @"config_hash": JSONSafe(CallObjectNoArg(properties, @"configHash"), 0),
            @"refresh_id": JSONSafe(CallObjectNoArg(properties, @"refreshID"), 0)
        },
        @"abi": @{
            @"top": @{ @"selector": kTopSelector, @"encoding": Encoding(managerClass, kTopSelector), @"exact": @(topOK) },
            @"lower": @{ @"selector": kLowerSelector, @"encoding": Encoding(managerClass, kLowerSelector), @"exact": @(lowerOK) },
            @"request_initializer": @{ @"selector": kRequestInitSelector, @"encoding": Encoding(requestClass, kRequestInitSelector), @"exact": @(initOK) },
            @"did_succeed": @{ @"selector": kDidSucceedSelector, @"encoding": Encoding(requestClass, kDidSucceedSelector), @"exact": @(didOK) },
            @"did_fail": @{ @"selector": kDidFailSelector, @"encoding": Encoding(requestClass, kDidFailSelector), @"exact": @(failOK) },
            @"handler": @{ @"selector": kHandleSelector, @"encoding": Encoding(managerClass, kHandleSelector), @"exact": @(handlerOK) }
        },
        @"correlation_hooks_installed": @(installed),
        @"correlation_hooks_active": @(hooksActive),
        @"transaction_gate": WAGRABPropsABTTransactionGateDocument(),
        @"native_store": SnapshotSummary(snapshot),
        @"custom_wire": @{
            @"supported_policies": @[@"native", @"nil", @"empty", @"zero", @"custom"],
            @"custom_value_max_length": @256,
            @"timeout_range_seconds": @[@45, @120]
        },
        @"variants": variants,
        @"binary_evidence": BinaryEvidence()
    };
}
