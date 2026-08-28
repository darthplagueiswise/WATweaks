#import "WAGRABPropsABTForceFull.h"
#import "WAGRABPropsABTTransactionGate.h"
#import "WAGRABPropsNativeStore.h"
#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

// The supplied SharedModules(5) contains a complete, active full-fetch route:
//
//   WAProperties.resetConfigHashToEmptyString
//     -> WAPropertiesStore.resetConfigHashToEmptyString
//     -> XMPPConnectionABPropsRequestManager.requestFreshABProps:NO
//     -> WAABPropsRequestBuilder reads configHash == @"" and refreshID == nil
//     -> native response handler replaces WAPropertiesStore and refills hash
//
// This implementation deliberately does not hook XMPPRequestABProperties (or
// any other request class). The empty hash is an intentional native state and
// the post-completion hash refill is the account-scoped proof that the handler
// applied a server response. A changed gabp fingerprint is useful secondary
// evidence, but is not required when a full response contains identical props.

static NSString * const kManagerSelector = @"requestFreshABProps:withCompletion:";
static NSString * const kResetHashSelector = @"resetConfigHashToEmptyString";
static NSString * const kConfigHashSelector = @"configHash";
static NSString * const kRefreshIDSelector = @"refreshID";

static const char *kManagerEncoding = "v28@0:8B16@?20";
static const char *kResetHashEncoding = "v16@0:8";
static const char *kObjectNoArgEncoding = "@16@0:8";

static NSObject *gForceLock;
static NSString *gPendingToken;
static NSDictionary<NSString *, id> *gForceDocument;

static void EnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gForceLock = [NSObject new];
        gForceDocument = @{
            @"schema": @"watweaks_abprops_abt_force_full_v2",
            @"outcome": @"not_run",
            @"hook_installed": @NO,
            @"pending": @NO
        };
    });
}

static NSTimeInterval Now(void) {
    return NSDate.date.timeIntervalSince1970;
}

static NSString *ClassName(id object) {
    return object ? (NSStringFromClass([object class]) ?: @"?") : @"nil";
}

static NSString *MethodEncoding(Class cls, NSString *selectorName) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? ([NSString stringWithUTF8String:encoding] ?: @"") : @"";
}

static BOOL MethodHasExactEncoding(id object, NSString *selectorName, const char *expected) {
    if (!object || !selectorName.length || !expected) return NO;
    Method method = class_getInstanceMethod([object class], NSSelectorFromString(selectorName));
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && strcmp(actual, expected) == 0;
}

static id CallObjectNoArg(id target, NSString *selectorName) {
    if (!MethodHasExactEncoding(target, selectorName, kObjectNoArgEncoding)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selectorName));
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id JSONValue(id value) {
    if (!value) return NSNull.null;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    NSString *description = nil;
    @try { description = [value description]; } @catch (__unused NSException *exception) {}
    if (description.length > 160) description = [[description substringToIndex:160] stringByAppendingString:@"…"];
    return @{ @"class": ClassName(value), @"description": description ?: @"" };
}

static NSString *HashString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *SnapshotSummary(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{ @"available": @NO };
    return @{
        @"available": @YES,
        @"prop_count": @(snapshot.numericPropCount),
        @"fingerprint": snapshot.fingerprint ?: @"",
        @"payload_key": snapshot.payloadKey.length ? @"gabp.<account>p" : @""
    };
}

static id ResolveLiveManager(id context, NSString **route) {
    if (!context) return nil;

    // This is the exact ownership route observed in this build. There is no
    // graph walk and no invocation of look-alike fetch/sync selectors.
    id manager = CallObjectNoArg(context, @"xmppConnectionABPropsRequestManager");
    if (MethodHasExactEncoding(manager, kManagerSelector, kManagerEncoding)) {
        if (route) *route = @"context.xmppConnectionABPropsRequestManager";
        return manager;
    }

    id provider = CallObjectNoArg(context, @"networkingDependencyProvider");
    if (!provider) provider = CallObjectNoArg(context, @"networking");
    id connection = CallObjectNoArg(provider, @"xmppConnection");
    if (!connection) connection = CallObjectNoArg(context, @"xmppConnection");

    manager = CallObjectNoArg(connection, @"xmppConnectionABPropsRequestManager");
    if (!manager) manager = CallObjectNoArg(provider, @"xmppConnectionABPropsRequestManager");
    if (MethodHasExactEncoding(manager, kManagerSelector, kManagerEncoding)) {
        if (route) {
            *route = [NSString stringWithFormat:@"context=%@ provider=%@ connection=%@ manager=%@",
                ClassName(context), ClassName(provider), ClassName(connection), ClassName(manager)];
        }
        return manager;
    }

    if (route) {
        *route = [NSString stringWithFormat:@"context=%@ provider=%@ connection=%@ manager=nil",
            ClassName(context), ClassName(provider), ClassName(connection)];
    }
    return nil;
}

static id ResolvePersonalABProperties(id context, NSString **diagnostic) {
    // WAABPropsRequestBuilder at 0x003f5838 obtains userContext and, for a nil
    // group JID, calls exactly -abProperties at 0x003f5858. Resolve that same
    // object so the hash we clear is the hash the builder will read.
    id properties = CallObjectNoArg(context, @"abProperties");
    if (!properties) {
        if (diagnostic) *diagnostic = @"userContext.abProperties did not resolve";
        return nil;
    }
    if (!MethodHasExactEncoding(properties, kResetHashSelector, kResetHashEncoding) ||
        !MethodHasExactEncoding(properties, kConfigHashSelector, kObjectNoArgEncoding) ||
        !MethodHasExactEncoding(properties, kRefreshIDSelector, kObjectNoArgEncoding)) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:
                @"%@ ABProps ABI mismatch: reset=%@ hash=%@ refreshID=%@",
                ClassName(properties),
                MethodEncoding([properties class], kResetHashSelector),
                MethodEncoding([properties class], kConfigHashSelector),
                MethodEncoding([properties class], kRefreshIDSelector)];
        }
        return nil;
    }
    return properties;
}

static NSDictionary *BinaryEvidence(void) {
    return @{
        @"sharedmodules_sha256": @"f0edef076c68d7f1f872401d774789a2cb3f50be5c96773a2d8ed763ed3015a7",
        @"requestFreshABProps_thunk": @"0x003f55f8",
        @"request_manager_full_path": @"0x003e5bf8",
        @"request_builder": @"0x003f5820",
        @"wa_properties_hash_reset": @"0x021db9a8",
        @"wa_properties_store_hash_reset": @"0x0214f72c",
        @"response_handler": @"0x003fee38",
        @"full_store_update_callsite": @"0x003ff0d0",
        @"delta_store_update_callsite": @"0x003ff0e0",
        @"wire_rule": @"deltaUpdate=NO reads configHash and sets refreshID=nil"
    };
}

static void PublishDocument(NSDictionary *document) {
    EnsureState();
    @synchronized (gForceLock) {
        gForceDocument = [document copy] ?: @{};
    }
}

static void MarkLateNativeCompletion(NSString *token) {
    EnsureState();
    NSDictionary *gateDocument = WAGRABPropsABTTransactionGateDocument();
    @synchronized (gForceLock) {
        if (![gForceDocument[@"token"] isEqualToString:token] ||
            ![gForceDocument[@"gate_quarantined_until_native_completion"] boolValue]) return;
        NSMutableDictionary *document = [gForceDocument mutableCopy];
        document[@"late_native_completion_observed"] = @YES;
        document[@"gate_quarantined_until_native_completion"] = @NO;
        document[@"gate_quarantine_released_time"] = @(Now());
        document[@"transaction_gate_after_late_completion"] = gateDocument;
        gForceDocument = [document copy];
    }
    WAGRLogAppendF(@"[ABProps][ABTForceFull] late native completion released gate token=%@",
                   token ?: @"?");
}

static void FinishTransaction(NSString *token,
                              id properties,
                              WAGRABPropsNativeSnapshot *before,
                              BOOL nativeCompletionObserved,
                              WAGRABPropsABTLiveCompletion completion) {
    EnsureState();
    @synchronized (gForceLock) {
        if (![gPendingToken isEqualToString:token]) return;
        gPendingToken = nil;
    }
    id directHashValue = CallObjectNoArg(properties, kConfigHashSelector);
    NSString *directHash = HashString(directHashValue);
    id directRefreshID = CallObjectNoArg(properties, kRefreshIDSelector);
    WAGRABPropsNativeSnapshot *after = WAGRABPropsReadNativeSnapshot(NULL);
    BOOL hashRefilled = directHash.length > 0;
    BOOL fingerprintChanged = before && after && after.fingerprint.length &&
        ![after.fingerprint isEqualToString:(before.fingerprint ?: @"")];
    NSString *outcome = nativeCompletionObserved
        ? (hashRefilled ? @"verified_native_completion_hash_refilled" : @"native_completion_without_refilled_hash")
        : @"timeout_waiting_native_completion";

    NSDictionary *storeConfirmation = @{
        @"verified": @(nativeCompletionObserved && hashRefilled),
        @"native_completion_observed": @(nativeCompletionObserved),
        @"config_hash_refilled": @(hashRefilled),
        @"config_hash": JSONValue(directHashValue),
        @"refresh_id": JSONValue(directRefreshID),
        @"fingerprint_changed": @(fingerprintChanged),
        @"effective_prop_count": @(after.numericPropCount),
        @"after": SnapshotSummary(after)
    };

    if (nativeCompletionObserved) WAGRABPropsABTTransactionRelease(token);
    NSDictionary *gateAfterFinish = WAGRABPropsABTTransactionGateDocument();
    NSString *interpretation = nil;
    if (!nativeCompletionObserved) {
        interpretation = @"The native retry pipeline did not complete within 45 seconds. The ABT gate remains quarantined until its late completion; restart WhatsApp if it never arrives. No new ABT transaction is allowed to overlap it.";
    } else if (hashRefilled) {
        interpretation = @"The exact account WAProperties hash was emptied before dispatch and was non-empty when checked after native completion. This verifies the hook-free postcondition, not direct wire/handler observation; use ABT Runtime Lab for that proof.";
    } else {
        interpretation = @"Dispatch/completion alone is not reported as success because the exact account WAProperties hash was not refilled.";
    }
    NSDictionary *result = @{
        @"schema": @"watweaks_abprops_abt_force_full_v2",
        @"outcome": outcome,
        @"token": token ?: @"",
        @"hook_installed": @NO,
        @"pending": @NO,
        @"native_completion_observed": @(nativeCompletionObserved),
        @"gate_quarantined_until_native_completion": @(!nativeCompletionObserved),
        @"validator_reset_confirmed": @YES,
        @"verified": @(nativeCompletionObserved && hashRefilled),
        @"wire_response_observed": @NO,
        @"request_mode": @"native_hash_reset_then_regular_request",
        @"effective_prop_count": @(after.numericPropCount),
        @"store_confirmation": storeConfirmation,
        @"before_store": SnapshotSummary(before),
        @"completed_time": @(Now()),
        @"binary_evidence": BinaryEvidence(),
        @"transaction_gate_after_finish": gateAfterFinish,
        @"interpretation": interpretation
    };
    PublishDocument(result);
    WAGRLogAppendF(@"[ABProps][ABTForceFull] token=%@ outcome=%@ hashRefilled=%@ props=%lu fingerprintChanged=%@",
                   token ?: @"?", outcome, hashRefilled ? @"YES" : @"NO",
                   (unsigned long)after.numericPropCount, fingerprintChanged ? @"YES" : @"NO");
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
}

static void FailReservedTransaction(NSString *token, NSDictionary *document) {
    EnsureState();
    BOOL reserved = NO;
    @synchronized (gForceLock) {
        if ([gPendingToken isEqualToString:token]) {
            gPendingToken = nil;
            gForceDocument = [document copy] ?: @{};
            reserved = YES;
        }
    }
    if (reserved) WAGRABPropsABTTransactionRelease(token);
}

BOOL WAGRABPropsABTLiveFetchForcedFull(id userContext,
                                       WAGRABPropsABTLiveCompletion completion,
                                       NSString **diagnostic) {
    EnsureState();
    id context = userContext ?: WAGRCurrentUserContext();
    if (!context) {
        if (diagnostic) *diagnostic = @"current WhatsApp user context is unavailable";
        return NO;
    }

    NSString *route = nil;
    id manager = ResolveLiveManager(context, &route);
    if (!manager) {
        NSString *text = [NSString stringWithFormat:@"live XMPPConnectionABPropsRequestManager unresolved (%@)", route ?: @"no route"];
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    NSString *propertiesDiagnostic = nil;
    id properties = ResolvePersonalABProperties(context, &propertiesDiagnostic);
    if (!properties) {
        if (diagnostic) *diagnostic = propertiesDiagnostic ?: @"personal WAProperties unresolved";
        return NO;
    }

    NSString *token = NSUUID.UUID.UUIDString;
    NSString *gateDiagnostic = nil;
    if (!WAGRABPropsABTTransactionAcquire(@"hook_free_force_full", token, &gateDiagnostic)) {
        if (diagnostic) *diagnostic = gateDiagnostic ?: @"another ABT transaction is active";
        return NO;
    }
    BOOL forceBusy = NO;
    @synchronized (gForceLock) {
        forceBusy = gPendingToken.length > 0;
        if (!forceBusy) gPendingToken = token;
    }
    if (forceBusy) {
        WAGRABPropsABTTransactionRelease(token);
        if (diagnostic) *diagnostic = @"another native full-fetch transaction is still pending";
        return NO;
    }

    WAGRABPropsNativeSnapshot *before = WAGRABPropsReadNativeSnapshot(NULL);
    id beforeHash = CallObjectNoArg(properties, kConfigHashSelector);
    id beforeRefreshID = CallObjectNoArg(properties, kRefreshIDSelector);

    @try {
        ((void (*)(id, SEL))objc_msgSend)(properties, NSSelectorFromString(kResetHashSelector));
    } @catch (NSException *exception) {
        NSString *text = [NSString stringWithFormat:@"resetConfigHashToEmptyString threw %@", exception.reason ?: @"exception"];
        NSDictionary *failure = @{
            @"schema": @"watweaks_abprops_abt_force_full_v2",
            @"outcome": @"native_hash_reset_threw",
            @"hook_installed": @NO,
            @"pending": @NO,
            @"exception": text,
            @"binary_evidence": BinaryEvidence()
        };
        FailReservedTransaction(token, failure);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    id resetHashValue = CallObjectNoArg(properties, kConfigHashSelector);
    NSString *resetHash = HashString(resetHashValue);
    BOOL resetConfirmed = resetHash != nil && resetHash.length == 0;
    if (!resetConfirmed) {
        NSString *text = [NSString stringWithFormat:@"native configHash reset was not observable (class=%@ value=%@)",
                          ClassName(resetHashValue), JSONValue(resetHashValue)];
        NSDictionary *failure = @{
            @"schema": @"watweaks_abprops_abt_force_full_v2",
            @"outcome": @"native_hash_reset_not_confirmed",
            @"hook_installed": @NO,
            @"pending": @NO,
            @"before_config_hash": JSONValue(beforeHash),
            @"after_reset_config_hash": JSONValue(resetHashValue),
            @"binary_evidence": BinaryEvidence()
        };
        FailReservedTransaction(token, failure);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    NSDictionary *pending = @{
        @"schema": @"watweaks_abprops_abt_force_full_v2",
        @"outcome": @"pending_native_completion",
        @"token": token,
        @"hook_installed": @NO,
        @"pending": @YES,
        @"validator_reset_confirmed": @YES,
        @"request_mode": @"native_hash_reset_then_regular_request",
        @"manager_class": ClassName(manager),
        @"properties_class": ClassName(properties),
        @"manager_route": route ?: @"",
        @"manager_encoding": MethodEncoding([manager class], kManagerSelector),
        @"before_config_hash": JSONValue(beforeHash),
        @"before_refresh_id": JSONValue(beforeRefreshID),
        @"after_reset_config_hash": JSONValue(resetHashValue),
        @"wire_config_hash": resetHashValue ? JSONValue(resetHashValue) : NSNull.null,
        @"wire_refresh_id": NSNull.null,
        @"before_store": SnapshotSummary(before),
        @"started_time": @(Now()),
        @"transaction_gate": WAGRABPropsABTTransactionGateDocument(),
        @"binary_evidence": BinaryEvidence()
    };
    PublishDocument(pending);

    __block NSString *requestToken = [token copy];
    __block id retainedProperties = properties;
    __block WAGRABPropsNativeSnapshot *retainedBefore = before;
    __block WAGRABPropsABTLiveCompletion retainedCompletion = [completion copy];
    void (^nativeCompletion)(void) = ^{
        // The manager completion runs after its retry/attempt pipeline. Give
        // cfprefsd a short settling window; account-scoped proof comes from the
        // direct WAProperties hash, not from assuming the plist changed.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            FinishTransaction(requestToken, retainedProperties, retainedBefore, YES, retainedCompletion);
            // Normal completion already releases the gate in FinishTransaction.
            // After a reported timeout this releases the quarantined token.
            WAGRABPropsABTTransactionRelease(requestToken);
            MarkLateNativeCompletion(requestToken);
        });
    };

    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager,
            NSSelectorFromString(kManagerSelector), NO, nativeCompletion);
    } @catch (NSException *exception) {
        NSString *text = [NSString stringWithFormat:
            @"requestFreshABProps:NO threw %@; configHash remains cleared so the next native sync will also request full state",
            exception.reason ?: @"exception"];
        NSDictionary *failure = @{
            @"schema": @"watweaks_abprops_abt_force_full_v2",
            @"outcome": @"native_request_threw_after_hash_reset",
            @"token": token,
            @"hook_installed": @NO,
            @"pending": @NO,
            @"validator_reset_confirmed": @YES,
            @"diagnostic": text,
            @"binary_evidence": BinaryEvidence()
        };
        FailReservedTransaction(token, failure);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FinishTransaction(requestToken, retainedProperties, retainedBefore, NO, retainedCompletion);
    });

    NSString *text = [NSString stringWithFormat:
        @"native full fetch dispatched: %@ → configHash cleared → requestFreshABProps:NO; awaiting native completion and hash refill",
        route ?: @"exact manager"];
    if (diagnostic) *diagnostic = text;
    WAGRLogAppendF(@"[ABProps][ABTForceFull] token=%@ reset confirmed, exact request dispatched via %@",
                   token, route ?: @"manager");
    return YES;
}

NSDictionary<NSString *, id> *WAGRABPropsABTForceFullDocument(void) {
    EnsureState();
    @synchronized (gForceLock) {
        return [gForceDocument copy] ?: @{};
    }
}
