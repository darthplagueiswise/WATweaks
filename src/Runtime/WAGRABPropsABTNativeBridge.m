#import "WAGRABPropsABTNativeBridge.h"
#import "WAGRABPropsNativeStore.h"
#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <string.h>

// Native ABProps session pipeline proven in the current SharedModules build:
//
// XMPPConnectionABPropsRequestManager
//   -requestFreshABProps:withCompletion:             v28@0:8B16@?20
//        -> WAABPropsRequestBuilder
//        -> XMPPRequestABProperties (xmlns=abt, to=s.whatsapp.net)
//        -> XMPPConnection enqueueRequest:
//
// XMPPRequestABProperties
//   -didSucceedWithResponse:                         v24@0:8@16
//        -> decoded props/sampling/hash/refresh fields
//        -> XMPPConnectionABPropsRequestManager
//           -handleABPropsResponseForGroupJID:...    v120@0:8@16@24@32@40i48@52@60q68@76@84B92q96q104@?112
//        -> WAProperties updateWithProperties:... / deltaUpdateWithNewProperties:...
//        -> WAPropertiesStore persisted backing (gabp.*p / gabp.*c)
//
// This bridge does not reconstruct the stanza, authentication or connection. It
// observes the exact native session and uses the exact request-manager ABI.

static NSString * const kWAGRABTManagerClass = @"XMPPConnectionABPropsRequestManager";
static NSString * const kWAGRABTRequestClass = @"XMPPRequestABProperties";
static NSString * const kWAGRABTManagerInitSelector = @"initWithUserContext:xmppConnection:";
static NSString * const kWAGRABTFetchSelector = @"requestFreshABProps:withCompletion:";
static NSString * const kWAGRABTDidSucceedSelector = @"didSucceedWithResponse:";
static NSString * const kWAGRABTHandleSelector = @"handleABPropsResponseForGroupJID:error:props:samplingWeights:protocolVersion:configKey:configHash:refreshInterval:refreshID:encryptedRID:isDeltaUpdate:attemptIndex:maxAttempts:attemptCompletion:";

static const char * const kWAGRABTManagerInitEncoding = "@32@0:8@16@24";
static const char * const kWAGRABTFetchEncoding = "v28@0:8B16@?20";
static const char * const kWAGRABTDidSucceedEncoding = "v24@0:8@16";
static const char * const kWAGRABTHandleEncoding = "v120@0:8@16@24@32@40i48@52@60q68@76@84B92q96q104@?112";

static __weak id gWAGRABTManager = nil;
static __weak id gWAGRABTContext = nil;
static id (*gWAGRABTOriginalManagerInit)(id, SEL, id, id) = NULL;
static void (*gWAGRABTOriginalDidSucceed)(id, SEL, id) = NULL;
static void (*gWAGRABTOriginalHandle)(id, SEL, id, id, id, id, int, id, id,
                                      int64_t, id, id, BOOL, int64_t, int64_t, id) = NULL;

static BOOL gWAGRABTManagerHookInstalled = NO;
static BOOL gWAGRABTDidSucceedHookInstalled = NO;
static BOOL gWAGRABTHandleHookInstalled = NO;

static NSObject *gWAGRABTLock = nil;
static NSMutableArray<NSDictionary *> *gWAGRABTEvents = nil;
static NSDictionary *gWAGRABTLastRequest = nil;
static NSDictionary *gWAGRABTLastDidSucceed = nil;
static NSDictionary *gWAGRABTLastDecodedResponse = nil;
static NSDictionary *gWAGRABTLastStoreConfirmation = nil;
static NSString *gWAGRABTLastDiagnostic = @"not attempted";
static NSString *gWAGRABTPendingToken = nil;
static NSString *gWAGRABTPendingBeforeFingerprint = nil;
static WAGRABPropsABTCompletion gWAGRABTPendingCompletion = nil;

static void WAGRABTEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRABTLock = [NSObject new];
        gWAGRABTEvents = [NSMutableArray array];
    });
}

static NSTimeInterval WAGRABTNow(void) {
    return [NSDate date].timeIntervalSince1970;
}

static NSString *WAGRABTClassName(id value) {
    return value ? (NSStringFromClass([value class]) ?: @"?") : @"nil";
}

static NSString *WAGRABTBoundedDescription(id value, NSUInteger maxLength) {
    if (!value) return @"nil";
    NSString *text = nil;
    @try { text = [value description]; }
    @catch (__unused NSException *exception) { text = @"<description threw>"; }
    if (!text) text = @"?";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length > maxLength) {
        text = [[text substringToIndex:maxLength] stringByAppendingString:@"…"];
    }
    return text;
}

static void WAGRABTSetDiagnostic(NSString *text) {
    WAGRABTEnsureState();
    @synchronized (gWAGRABTLock) {
        gWAGRABTLastDiagnostic = [text copy] ?: @"unknown";
    }
    WAGRLogAppendF(@"[ABProps][ABT] %@", text ?: @"unknown");
}

static void WAGRABTEvent(NSString *name, NSDictionary *fields) {
    WAGRABTEnsureState();
    NSMutableDictionary *event = [@{
        @"time": @(WAGRABTNow()),
        @"event": name ?: @"?"
    } mutableCopy];
    if ([fields isKindOfClass:NSDictionary.class]) [event addEntriesFromDictionary:fields];
    @synchronized (gWAGRABTLock) {
        [gWAGRABTEvents addObject:event];
        if (gWAGRABTEvents.count > 96) {
            [gWAGRABTEvents removeObjectsInRange:NSMakeRange(0, gWAGRABTEvents.count - 96)];
        }
    }
}

static BOOL WAGRABTMethodEncodingIs(Method method, const char *expected) {
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && expected && strcmp(actual, expected) == 0;
}

static NSString *WAGRABTEncoding(Class cls, NSString *selectorName) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? ([NSString stringWithUTF8String:encoding] ?: @"") : @"";
}

static id WAGRABTCallObjectNoArg(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    if (raw[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABTResolveManager(id context) {
    id captured = gWAGRABTManager;
    if (captured) {
        Method fetch = class_getInstanceMethod([captured class], NSSelectorFromString(kWAGRABTFetchSelector));
        if (WAGRABTMethodEncodingIs(fetch, kWAGRABTFetchEncoding)) return captured;
    }

    id root = context ?: WAGRCurrentUserContext() ?: gWAGRABTContext;
    if (!root) return nil;

    id manager = WAGRABTCallObjectNoArg(root, @"xmppConnectionABPropsRequestManager");
    if (manager) {
        Method fetch = class_getInstanceMethod([manager class], NSSelectorFromString(kWAGRABTFetchSelector));
        if (WAGRABTMethodEncodingIs(fetch, kWAGRABTFetchEncoding)) return manager;
    }

    id provider = WAGRABTCallObjectNoArg(root, @"networkingDependencyProvider");
    if (!provider) provider = WAGRABTCallObjectNoArg(root, @"networking");
    id connection = WAGRABTCallObjectNoArg(provider, @"xmppConnection");
    if (!connection) connection = WAGRABTCallObjectNoArg(root, @"xmppConnection");

    manager = WAGRABTCallObjectNoArg(connection, @"xmppConnectionABPropsRequestManager");
    if (!manager) manager = WAGRABTCallObjectNoArg(provider, @"xmppConnectionABPropsRequestManager");
    if (manager) {
        Method fetch = class_getInstanceMethod([manager class], NSSelectorFromString(kWAGRABTFetchSelector));
        if (WAGRABTMethodEncodingIs(fetch, kWAGRABTFetchEncoding)) return manager;
    }
    return nil;
}

static id WAGRABTManagerInit(id self, SEL _cmd, id userContext, id xmppConnection) {
    id result = gWAGRABTOriginalManagerInit
        ? gWAGRABTOriginalManagerInit(self, _cmd, userContext, xmppConnection) : self;
    id manager = result ?: self;
    Method fetch = class_getInstanceMethod([manager class], NSSelectorFromString(kWAGRABTFetchSelector));
    if (WAGRABTMethodEncodingIs(fetch, kWAGRABTFetchEncoding)) {
        gWAGRABTManager = manager;
        if (userContext) {
            gWAGRABTContext = userContext;
            WAGRRememberUserContext(userContext, @"native ABT manager initializer");
        }
        WAGRABTEvent(@"manager_captured", @{
            @"manager_class": WAGRABTClassName(manager),
            @"context_class": WAGRABTClassName(userContext),
            @"connection_class": WAGRABTClassName(xmppConnection)
        });
    }
    return result;
}

static id WAGRABTReadNoArgValue(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    @try {
        switch (raw[0]) {
            case '@': return ((id (*)(id, SEL))objc_msgSend)(object, selector);
            case 'B': return @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector));
            case 'c': return @(((char (*)(id, SEL))objc_msgSend)(object, selector));
            case 'C': return @(((unsigned char (*)(id, SEL))objc_msgSend)(object, selector));
            case 's': return @(((short (*)(id, SEL))objc_msgSend)(object, selector));
            case 'S': return @(((unsigned short (*)(id, SEL))objc_msgSend)(object, selector));
            case 'i': return @(((int (*)(id, SEL))objc_msgSend)(object, selector));
            case 'I': return @(((unsigned int (*)(id, SEL))objc_msgSend)(object, selector));
            case 'l': return @(((long (*)(id, SEL))objc_msgSend)(object, selector));
            case 'L': return @(((unsigned long (*)(id, SEL))objc_msgSend)(object, selector));
            case 'q': return @(((long long (*)(id, SEL))objc_msgSend)(object, selector));
            case 'Q': return @(((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector));
            case 'f': return @(((float (*)(id, SEL))objc_msgSend)(object, selector));
            case 'd': return @(((double (*)(id, SEL))objc_msgSend)(object, selector));
            default: return nil;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id WAGRABTJSONSafe(id value, NSUInteger depth) {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 8) return WAGRABTBoundedDescription(value, 256);
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDate.class]) return [(NSDate *)value description] ?: @"";
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSData.class]) return [(NSData *)value base64EncodedStringWithOptions:0] ?: @"";
    if ([value isKindOfClass:NSError.class]) {
        NSError *error = value;
        return @{
            @"domain": error.domain ?: @"",
            @"code": @(error.code),
            @"description": error.localizedDescription ?: @""
        };
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) [out addObject:WAGRABTJSONSafe(item, depth + 1) ?: NSNull.null];
        return out;
    }
    if ([value isKindOfClass:NSSet.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSSet *)value) [out addObject:WAGRABTJSONSafe(item, depth + 1) ?: NSNull.null];
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)value count]];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, __unused BOOL *stop) {
            NSString *safeKey = [key isKindOfClass:NSString.class] ? key : [key description];
            if (safeKey.length) out[safeKey] = WAGRABTJSONSafe(object, depth + 1) ?: NSNull.null;
        }];
        return out;
    }

    // The native handler already receives parsed ABProp objects. Export the
    // stable fields without KVC or ivar walking. Different current-build model
    // classes expose slightly different subsets of these zero-argument getters.
    NSMutableDictionary *known = [NSMutableDictionary dictionary];
    for (NSString *field in @[
        @"key", @"value", @"expoKey", @"configCode", @"configValue",
        @"configExpoKey", @"eventCode", @"samplingWeight"
    ]) {
        id fieldValue = WAGRABTReadNoArgValue(value, field);
        if (fieldValue) known[field] = WAGRABTJSONSafe(fieldValue, depth + 1) ?: NSNull.null;
    }
    if (known.count) {
        known[@"_class"] = WAGRABTClassName(value);
        return known;
    }
    return @{
        @"_class": WAGRABTClassName(value),
        @"description": WAGRABTBoundedDescription(value, 512)
    };
}

static NSUInteger WAGRABTCollectionCount(id value) {
    if ([value respondsToSelector:@selector(count)]) {
        @try { return (NSUInteger)[value count]; }
        @catch (__unused NSException *exception) {}
    }
    return value ? 1 : 0;
}

static NSString *WAGRABTStringValue(id value) {
    if (!value || value == NSNull.null) return nil;
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) {
        @try {
            id string = [value stringValue];
            if ([string isKindOfClass:NSString.class]) return string;
        } @catch (__unused NSException *exception) {}
    }
    return [value description];
}

static id WAGRABTMetadataValue(NSDictionary *metadata, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = metadata[key];
        if (value) return value;
    }
    return nil;
}

static NSDictionary *WAGRABTSnapshotSummary(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{ @"available": @NO };
    NSDictionary *metadata = snapshot.metadata ?: @{};
    NSMutableDictionary *out = [@{
        @"available": @YES,
        @"prop_count": @(snapshot.numericPropCount),
        @"fingerprint": snapshot.fingerprint ?: @"",
        @"payload_key": snapshot.payloadKey.length ? @"gabp.<account>p" : @"",
        @"metadata_key": snapshot.metadataKey.length ? @"gabp.<account>c" : @""
    } mutableCopy];
    id hash = WAGRABTMetadataValue(metadata, @[@"hash", @"configHash"]);
    id refreshID = WAGRABTMetadataValue(metadata, @[@"refreshID", @"refreshId", @"refresh_id"]);
    id encryptedRID = WAGRABTMetadataValue(metadata, @[@"encryptedRID", @"encryptedRid", @"erid"]);
    id refreshInterval = WAGRABTMetadataValue(metadata, @[@"refreshInterval", @"refresh"]);
    if (hash) out[@"hash"] = WAGRABTJSONSafe(hash, 0);
    if (refreshID) out[@"refresh_id"] = WAGRABTJSONSafe(refreshID, 0);
    if (encryptedRID) out[@"encrypted_rid"] = WAGRABTJSONSafe(encryptedRID, 0);
    if (refreshInterval) out[@"refresh_interval"] = WAGRABTJSONSafe(refreshInterval, 0);
    return out;
}

static BOOL WAGRABTStringsEqual(id left, id right) {
    NSString *a = WAGRABTStringValue(left);
    NSString *b = WAGRABTStringValue(right);
    if (!a.length || !b.length) return NO;
    return [a isEqualToString:b];
}

static void WAGRABTFinishPending(NSString *token, NSDictionary *result) {
    WAGRABPropsABTCompletion completion = nil;
    WAGRABTEnsureState();
    @synchronized (gWAGRABTLock) {
        if (!token.length || ![gWAGRABTPendingToken isEqualToString:token]) return;
        completion = [gWAGRABTPendingCompletion copy];
        gWAGRABTPendingCompletion = nil;
        gWAGRABTPendingToken = nil;
        gWAGRABTPendingBeforeFingerprint = nil;
    }
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result ?: @{}); });
    }
}

static void WAGRABTConfirmPersistedStore(NSString *token,
                                         NSString *beforeFingerprint,
                                         id props,
                                         id configHash,
                                         id refreshID,
                                         id encryptedRID,
                                         BOOL isDeltaUpdate) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        WAGRABPropsNativeSnapshot *after = nil;
        BOOL changed = NO;
        // This bounded wait happens only after the native decoded-response
        // handler returned. It confirms persistence; it is not used to infer
        // whether the network request succeeded.
        const NSTimeInterval delays[] = {0.0, 0.05, 0.20, 0.50, 1.00};
        for (NSUInteger index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
            if (delays[index] > 0) [NSThread sleepForTimeInterval:delays[index]];
            after = WAGRABPropsReadNativeSnapshot(NULL);
            changed = after.fingerprint.length && beforeFingerprint.length &&
                      ![after.fingerprint isEqualToString:beforeFingerprint];
            if (changed) break;
        }

        NSDictionary *metadata = after.metadata ?: @{};
        id persistedHash = WAGRABTMetadataValue(metadata, @[@"hash", @"configHash"]);
        id persistedRefreshID = WAGRABTMetadataValue(metadata, @[@"refreshID", @"refreshId", @"refresh_id"]);
        id persistedEncryptedRID = WAGRABTMetadataValue(metadata, @[@"encryptedRID", @"encryptedRid", @"erid"]);
        BOOL hashMatch = configHash ? WAGRABTStringsEqual(configHash, persistedHash) : YES;
        BOOL refreshMatch = refreshID ? WAGRABTStringsEqual(refreshID, persistedRefreshID) : YES;
        BOOL eridMatch = encryptedRID ? WAGRABTStringsEqual(encryptedRID, persistedEncryptedRID) : YES;
        // The active delta pair only receives properties + refreshID. The
        // encrypted RID belongs to the full-replace persistence contract.
        BOOL encryptedRIDPersistenceExpected = !isDeltaUpdate;
        BOOL responseMetadataMatches = hashMatch && refreshMatch &&
                                       (!encryptedRIDPersistenceExpected || eridMatch);

        NSDictionary *confirmation = @{
            @"checked_after_native_handler": @YES,
            @"source": @"WAPropertiesStore persisted backing / group.net.whatsapp.WhatsApp.shared gabp.*p+gabp.*c",
            @"cache_available": @(after != nil),
            @"fingerprint_changed": @(changed),
            @"response_prop_count": @(WAGRABTCollectionCount(props)),
            @"delta_update": @(isDeltaUpdate),
            @"config_hash_matches_persisted": @(hashMatch),
            @"refresh_id_matches_persisted": @(refreshMatch),
            @"encrypted_rid_matches_persisted": @(eridMatch),
            @"encrypted_rid_persistence_expected": @(encryptedRIDPersistenceExpected),
            @"response_metadata_matches_persisted": @(responseMetadataMatches),
            @"after": WAGRABTSnapshotSummary(after)
        };
        @synchronized (gWAGRABTLock) {
            gWAGRABTLastStoreConfirmation = confirmation;
        }
        WAGRABTEvent(@"wa_properties_store_confirmed", confirmation);
        WAGRABTSetDiagnostic([NSString stringWithFormat:
            @"ABT handler complete; props=%lu delta=%@ persisted=%@ fingerprintChanged=%@",
            (unsigned long)WAGRABTCollectionCount(props),
            isDeltaUpdate ? @"YES" : @"NO",
            after ? @"YES" : @"NO",
            changed ? @"YES" : @"NO"]);

        NSDictionary *result = WAGRABPropsABTNativeBridgeDocument();
        WAGRABTFinishPending(token, result);
    });
}

static void WAGRABTDidSucceed(id self, SEL _cmd, id response) {
    NSDictionary *record = @{
        @"time": @(WAGRABTNow()),
        @"request_class": WAGRABTClassName(self),
        @"response_class": WAGRABTClassName(response),
        @"response_description": WAGRABTBoundedDescription(response, 2048)
    };
    @synchronized (gWAGRABTLock) { gWAGRABTLastDidSucceed = record; }
    WAGRABTEvent(@"did_succeed_with_response", record);
    if (gWAGRABTOriginalDidSucceed) gWAGRABTOriginalDidSucceed(self, _cmd, response);
}

static void WAGRABTHandle(id self, SEL _cmd,
                          id groupJID,
                          id error,
                          id props,
                          id samplingWeights,
                          int protocolVersion,
                          id configKey,
                          id configHash,
                          int64_t refreshInterval,
                          id refreshID,
                          id encryptedRID,
                          BOOL isDeltaUpdate,
                          int64_t attemptIndex,
                          int64_t maxAttempts,
                          id attemptCompletion) {
    // Preserve WhatsApp semantics first. The response objects are retained by
    // ARC locals and converted to JSON only after the native apply path returns.
    if (gWAGRABTOriginalHandle) {
        gWAGRABTOriginalHandle(self, _cmd, groupJID, error, props, samplingWeights,
                               protocolVersion, configKey, configHash, refreshInterval,
                               refreshID, encryptedRID, isDeltaUpdate, attemptIndex,
                               maxAttempts, attemptCompletion);
    }

    NSString *pendingToken = nil;
    NSString *beforeFingerprint = nil;
    @synchronized (gWAGRABTLock) {
        // Explicit browser fetch is account-scoped. Do not let an unrelated
        // group ABProps response satisfy its completion.
        if (!groupJID && gWAGRABTPendingToken.length) {
            pendingToken = [gWAGRABTPendingToken copy];
            beforeFingerprint = [gWAGRABTPendingBeforeFingerprint copy] ?: @"";
        }
    }

    id retainedProps = props;
    id retainedSampling = samplingWeights;
    id retainedGroup = groupJID;
    id retainedError = error;
    id retainedConfigKey = configKey;
    id retainedConfigHash = configHash;
    id retainedRefreshID = refreshID;
    id retainedEncryptedRID = encryptedRID;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *decoded = @{
            @"time": @(WAGRABTNow()),
            @"manager_class": WAGRABTClassName(self),
            @"group_jid": WAGRABTJSONSafe(retainedGroup, 0),
            @"error": WAGRABTJSONSafe(retainedError, 0),
            @"props": WAGRABTJSONSafe(retainedProps, 0),
            @"prop_count": @(WAGRABTCollectionCount(retainedProps)),
            @"sampling_weights": WAGRABTJSONSafe(retainedSampling, 0),
            @"sampling_count": @(WAGRABTCollectionCount(retainedSampling)),
            @"protocol_version": @(protocolVersion),
            @"config_key": WAGRABTJSONSafe(retainedConfigKey, 0),
            @"config_hash": WAGRABTJSONSafe(retainedConfigHash, 0),
            @"refresh_interval": @(refreshInterval),
            @"refresh_id": WAGRABTJSONSafe(retainedRefreshID, 0),
            @"encrypted_rid": WAGRABTJSONSafe(retainedEncryptedRID, 0),
            @"delta_update": @(isDeltaUpdate),
            @"attempt_index": @(attemptIndex),
            @"max_attempts": @(maxAttempts)
        };
        @synchronized (gWAGRABTLock) { gWAGRABTLastDecodedResponse = decoded; }
        WAGRABTEvent(@"decoded_handler_observed", @{
            @"prop_count": @(WAGRABTCollectionCount(retainedProps)),
            @"sampling_count": @(WAGRABTCollectionCount(retainedSampling)),
            @"protocol_version": @(protocolVersion),
            @"delta_update": @(isDeltaUpdate),
            @"has_error": @(retainedError != nil)
        });

        if (pendingToken.length) {
            WAGRABTConfirmPersistedStore(pendingToken, beforeFingerprint ?: @"",
                                         retainedProps, retainedConfigHash, retainedRefreshID,
                                         retainedEncryptedRID, isDeltaUpdate);
        } else {
            // Native background syncs are exported too; confirm their resulting
            // store state without manufacturing an explicit request completion.
            WAGRABTConfirmPersistedStore(@"", @"", retainedProps, retainedConfigHash,
                                         retainedRefreshID, retainedEncryptedRID, isDeltaUpdate);
        }
    });
}

static BOOL WAGRABTInstallManagerHook(void) {
    if (gWAGRABTManagerHookInstalled) return YES;
    Class cls = NSClassFromString(kWAGRABTManagerClass) ?: objc_getClass(kWAGRABTManagerClass.UTF8String);
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(kWAGRABTManagerInitSelector)) : NULL;
    if (!WAGRABTMethodEncodingIs(method, kWAGRABTManagerInitEncoding)) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)WAGRABTManagerInit) {
        gWAGRABTOriginalManagerInit = (id (*)(id, SEL, id, id))current;
        method_setImplementation(method, (IMP)WAGRABTManagerInit);
    }
    gWAGRABTManagerHookInstalled = YES;
    return YES;
}

static BOOL WAGRABTInstallDidSucceedHook(void) {
    if (gWAGRABTDidSucceedHookInstalled) return YES;
    Class cls = NSClassFromString(kWAGRABTRequestClass) ?: objc_getClass(kWAGRABTRequestClass.UTF8String);
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(kWAGRABTDidSucceedSelector)) : NULL;
    if (!WAGRABTMethodEncodingIs(method, kWAGRABTDidSucceedEncoding)) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)WAGRABTDidSucceed) {
        gWAGRABTOriginalDidSucceed = (void (*)(id, SEL, id))current;
        method_setImplementation(method, (IMP)WAGRABTDidSucceed);
    }
    gWAGRABTDidSucceedHookInstalled = YES;
    return YES;
}

static BOOL WAGRABTInstallHandleHook(void) {
    if (gWAGRABTHandleHookInstalled) return YES;
    Class cls = NSClassFromString(kWAGRABTManagerClass) ?: objc_getClass(kWAGRABTManagerClass.UTF8String);
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(kWAGRABTHandleSelector)) : NULL;
    if (!WAGRABTMethodEncodingIs(method, kWAGRABTHandleEncoding)) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)WAGRABTHandle) {
        gWAGRABTOriginalHandle = (void (*)(id, SEL, id, id, id, id, int, id, id,
                                           int64_t, id, id, BOOL, int64_t, int64_t, id))current;
        method_setImplementation(method, (IMP)WAGRABTHandle);
    }
    gWAGRABTHandleHookInstalled = YES;
    return YES;
}

static void WAGRABTInstallHooks(void) {
    WAGRABTEnsureState();
    BOOL manager = WAGRABTInstallManagerHook();
    BOOL response = WAGRABTInstallDidSucceedHook();
    BOOL handler = WAGRABTInstallHandleHook();
    if (manager || response || handler) {
        WAGRABTEvent(@"hooks_checked", @{
            @"manager_initializer": @(manager),
            @"did_succeed": @(response),
            @"decoded_handler": @(handler)
        });
    }
}

BOOL WAGRABPropsABTTriggerFetch(id userContext,
                                BOOL refreshIDBranch,
                                WAGRABPropsABTCompletion completion,
                                NSString **diagnostic) {
    WAGRABTInstallHooks();
    id context = userContext ?: WAGRCurrentUserContext() ?: gWAGRABTContext;
    id manager = WAGRABTResolveManager(context);
    if (!manager) {
        NSString *text = @"live XMPPConnectionABPropsRequestManager unresolved; ABT request not sent";
        WAGRABTSetDiagnostic(text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    Method fetchMethod = class_getInstanceMethod([manager class], NSSelectorFromString(kWAGRABTFetchSelector));
    if (!WAGRABTMethodEncodingIs(fetchMethod, kWAGRABTFetchEncoding)) {
        NSString *text = [NSString stringWithFormat:@"requestFreshABProps ABI mismatch: %@",
                          WAGRABTEncoding([manager class], kWAGRABTFetchSelector)];
        WAGRABTSetDiagnostic(text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    WAGRABPropsNativeSnapshot *before = WAGRABPropsReadNativeSnapshot(NULL);
    NSString *token = NSUUID.UUID.UUIDString;
    NSDictionary *request = @{
        @"time": @(WAGRABTNow()),
        @"token": token,
        @"manager_class": WAGRABTClassName(manager),
        @"context_class": WAGRABTClassName(context),
        @"selector": kWAGRABTFetchSelector,
        @"encoding": WAGRABTEncoding([manager class], kWAGRABTFetchSelector),
        @"refresh_id_branch": @(refreshIDBranch),
        @"branch": refreshIDBranch ? @"refresh_id" : @"regular_config_hash",
        @"before": WAGRABTSnapshotSummary(before)
    };

    WAGRABTEnsureState();
    @synchronized (gWAGRABTLock) {
        if (gWAGRABTPendingToken.length) {
            NSString *text = @"another explicit ABT fetch is still awaiting the native handler";
            if (diagnostic) *diagnostic = text;
            return NO;
        }
        gWAGRABTManager = manager;
        if (context) gWAGRABTContext = context;
        gWAGRABTLastRequest = request;
        gWAGRABTPendingToken = token;
        gWAGRABTPendingBeforeFingerprint = before.fingerprint ?: @"";
        gWAGRABTPendingCompletion = [completion copy];
    }

    __block NSString *requestToken = [token copy];
    void (^nativeCompletion)(void) = ^{
        WAGRABTEvent(@"native_request_completion_invoked", @{ @"token": requestToken ?: @"" });
    };

    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager,
            NSSelectorFromString(kWAGRABTFetchSelector), refreshIDBranch, nativeCompletion);
    } @catch (NSException *exception) {
        @synchronized (gWAGRABTLock) {
            if ([gWAGRABTPendingToken isEqualToString:token]) {
                gWAGRABTPendingToken = nil;
                gWAGRABTPendingBeforeFingerprint = nil;
                gWAGRABTPendingCompletion = nil;
            }
        }
        NSString *text = [NSString stringWithFormat:@"native ABT request threw %@",
                          exception.reason ?: @"exception"];
        WAGRABTSetDiagnostic(text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    WAGRABTEvent(@"explicit_request_sent", @{
        @"token": token,
        @"branch": refreshIDBranch ? @"refresh_id" : @"regular_config_hash"
    });
    NSString *text = [NSString stringWithFormat:
        @"ABT request sent via -[%@ %@] branch=%@; awaiting didSucceed + decoded handler",
        WAGRABTClassName(manager), kWAGRABTFetchSelector,
        refreshIDBranch ? @"refresh_id" : @"regular_config_hash"];
    WAGRABTSetDiagnostic(text);
    if (diagnostic) *diagnostic = text;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL stillPending = NO;
        @synchronized (gWAGRABTLock) {
            stillPending = [gWAGRABTPendingToken isEqualToString:token];
        }
        if (!stillPending) return;
        WAGRABPropsNativeSnapshot *after = WAGRABPropsReadNativeSnapshot(NULL);
        NSDictionary *timeout = @{
            @"checked_after_native_handler": @NO,
            @"outcome": @"timeout_waiting_decoded_native_handler",
            @"after": WAGRABTSnapshotSummary(after)
        };
        @synchronized (gWAGRABTLock) { gWAGRABTLastStoreConfirmation = timeout; }
        WAGRABTEvent(@"explicit_request_timeout", @{ @"token": token });
        WAGRABTSetDiagnostic(@"ABT request dispatched but decoded native handler was not observed within 10 s");
        WAGRABTFinishPending(token, WAGRABPropsABTNativeBridgeDocument());
    });
    return YES;
}

NSDictionary<NSString *, id> *WAGRABPropsABTNativeBridgeDocument(void) {
    WAGRABTEnsureState();
    Class managerClass = NSClassFromString(kWAGRABTManagerClass) ?: objc_getClass(kWAGRABTManagerClass.UTF8String);
    Class requestClass = NSClassFromString(kWAGRABTRequestClass) ?: objc_getClass(kWAGRABTRequestClass.UTF8String);
    @synchronized (gWAGRABTLock) {
        return @{
            @"schema": @"watweaks_abprops_abt_native_bridge_v1",
            @"protocol": @{
                @"xmlns": @"abt",
                @"to": @"s.whatsapp.net",
                @"iq_type": @"get",
                @"props_protocol": @"1",
                @"regular_branch": @"configHash",
                @"refresh_branch": @"refreshID"
            },
            @"manager_capture": @{
                @"captured": @(gWAGRABTManager != nil),
                @"manager_class": WAGRABTClassName(gWAGRABTManager),
                @"context_class": WAGRABTClassName(gWAGRABTContext)
            },
            @"hooks": @{
                @"manager_initializer_installed": @(gWAGRABTManagerHookInstalled),
                @"manager_initializer_encoding": WAGRABTEncoding(managerClass, kWAGRABTManagerInitSelector),
                @"request_fresh_encoding": WAGRABTEncoding(managerClass, kWAGRABTFetchSelector),
                @"did_succeed_installed": @(gWAGRABTDidSucceedHookInstalled),
                @"did_succeed_encoding": WAGRABTEncoding(requestClass, kWAGRABTDidSucceedSelector),
                @"decoded_handler_installed": @(gWAGRABTHandleHookInstalled),
                @"decoded_handler_encoding": WAGRABTEncoding(managerClass, kWAGRABTHandleSelector)
            },
            @"pending_explicit_request": @(gWAGRABTPendingToken.length > 0),
            @"last_request": gWAGRABTLastRequest ?: @{},
            @"did_succeed_response": gWAGRABTLastDidSucceed ?: @{},
            @"decoded_response": gWAGRABTLastDecodedResponse ?: @{},
            @"wa_properties_store_confirmation": gWAGRABTLastStoreConfirmation ?: @{},
            @"diagnostic": gWAGRABTLastDiagnostic ?: @"",
            @"events": [gWAGRABTEvents copy] ?: @[]
        };
    }
}

NSString *WAGRABPropsABTNativeBridgeDiagnosticText(void) {
    NSDictionary *document = WAGRABPropsABTNativeBridgeDocument();
    NSData *data = [NSJSONSerialization dataWithJSONObject:document
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    return data.length ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"")
                       : [document description];
}
