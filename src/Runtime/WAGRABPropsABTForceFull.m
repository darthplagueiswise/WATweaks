#import "WAGRABPropsABTForceFull.h"
#import "WAGRABPropsNativeStore.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#include <string.h>

static NSString * const kRequestClassName = @"XMPPRequestABProperties";
static NSString * const kRequestInitSelector = @"initWithUserContext:groupJID:configHash:refreshID:completion:";
static const char *kRequestInitEncoding = "@56@0:8@16@24@32@40@?48";

typedef id (*WAGRABPropsRequestInitIMP)(id, SEL, id, id, id, id, id);
static WAGRABPropsRequestInitIMP gOriginalRequestInit = NULL;

static NSObject *gForceLock;
static BOOL gForceHookInstalled = NO;
static BOOL gForceArmed = NO;
static BOOL gForceApplied = NO;
static NSTimeInterval gForceArmTime = 0;
static NSString *gForceTransactionToken;
static NSDictionary<NSString *, id> *gForceDocument;

static void EnsureForceState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gForceLock = [NSObject new];
        gForceDocument = @{
            @"schema": @"watweaks_abprops_abt_force_full_v1",
            @"hook_installed": @NO,
            @"armed": @NO,
            @"applied": @NO,
            @"outcome": @"not_run"
        };
    });
}

static NSString *ClassName(id object) {
    return object ? (NSStringFromClass([object class]) ?: @"?") : @"nil";
}

static id CompactValue(id value) {
    if (!value) return NSNull.null;
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        if (string.length <= 160) return string;
        return [[string substringToIndex:160] stringByAppendingString:@"…"];
    }
    if ([value isKindOfClass:NSNumber.class]) return value;
    return @{ @"class": ClassName(value), @"description": [[value description] ?: @"" substringToIndex:MIN((NSUInteger)160, [[value description] ?: @"" length])] };
}

static NSString *MethodEncoding(Class cls, SEL selector) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *raw = method ? method_getTypeEncoding(method) : NULL;
    return raw ? ([NSString stringWithUTF8String:raw] ?: @"") : @"";
}

static BOOL ExactEncoding(Method method, const char *expected) {
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && expected && strcmp(actual, expected) == 0;
}

static BOOL LiveServiceShowsOurExplicitRequest(NSString **tokenOut) {
    NSDictionary *document = WAGRABPropsABTLiveServiceDocument();
    if (![document isKindOfClass:NSDictionary.class]) return NO;
    if (![document[@"outcome"] isEqual:@"pending"]) return NO;
    if (![document[@"lower_request_entered"] boolValue]) return NO;
    NSDictionary *request = [document[@"request"] isKindOfClass:NSDictionary.class] ? document[@"request"] : nil;
    if (!request) return NO;
    if ([request[@"delta_update_requested"] boolValue]) return NO;
    NSString *token = [request[@"token"] isKindOfClass:NSString.class] ? request[@"token"] : nil;
    if (!token.length) return NO;
    if (tokenOut) *tokenOut = token;
    return YES;
}

static id ForceFullRequestInitHook(id self, SEL _cmd,
                                   id userContext,
                                   id groupJID,
                                   id configHash,
                                   id refreshID,
                                   id completion) {
    BOOL shouldForce = NO;
    NSString *token = nil;
    EnsureForceState();

    @synchronized (gForceLock) {
        if (gForceArmed && !gForceApplied && groupJID == nil) {
            shouldForce = LiveServiceShowsOurExplicitRequest(&token);
            if (shouldForce) {
                gForceApplied = YES;
                gForceArmed = NO;
                gForceTransactionToken = token;
                NSMutableDictionary *doc = [gForceDocument mutableCopy] ?: [NSMutableDictionary dictionary];
                doc[@"hook_installed"] = @YES;
                doc[@"armed"] = @NO;
                doc[@"applied"] = @YES;
                doc[@"outcome"] = @"validators_stripped_before_native_request_init";
                doc[@"transaction_token"] = token ?: @"";
                doc[@"applied_time"] = @([NSDate date].timeIntervalSince1970);
                doc[@"constructor"] = @{
                    @"class": kRequestClassName,
                    @"selector": kRequestInitSelector,
                    @"encoding": MethodEncoding([self class], _cmd),
                    @"group_jid": NSNull.null,
                    @"original_config_hash": CompactValue(configHash),
                    @"original_refresh_id": CompactValue(refreshID),
                    @"forwarded_config_hash": NSNull.null,
                    @"forwarded_refresh_id": NSNull.null
                };
                gForceDocument = doc;
            }
        }
    }

    if (shouldForce) {
        WAGRLogAppendF(@"[ABProps][ABTForceFull] token=%@ stripped configHash=%@ refreshID=%@",
                       token ?: @"?", CompactValue(configHash), CompactValue(refreshID));
        return gOriginalRequestInit
            ? gOriginalRequestInit(self, _cmd, userContext, groupJID, nil, nil, completion)
            : nil;
    }

    return gOriginalRequestInit
        ? gOriginalRequestInit(self, _cmd, userContext, groupJID, configHash, refreshID, completion)
        : nil;
}

static BOOL InstallForceHook(void) {
    EnsureForceState();
    if (gForceHookInstalled) return YES;

    Class cls = NSClassFromString(kRequestClassName) ?: objc_getClass(kRequestClassName.UTF8String);
    SEL selector = NSSelectorFromString(kRequestInitSelector);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!ExactEncoding(method, kRequestInitEncoding)) {
        @synchronized (gForceLock) {
            gForceDocument = @{
                @"schema": @"watweaks_abprops_abt_force_full_v1",
                @"hook_installed": @NO,
                @"armed": @NO,
                @"applied": @NO,
                @"outcome": @"constructor_abi_mismatch",
                @"expected_encoding": [NSString stringWithUTF8String:kRequestInitEncoding],
                @"actual_encoding": cls ? MethodEncoding(cls, selector) : @"class_unavailable"
            };
        }
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)ForceFullRequestInitHook) {
        gOriginalRequestInit = (WAGRABPropsRequestInitIMP)current;
        method_setImplementation(method, (IMP)ForceFullRequestInitHook);
    }
    gForceHookInstalled = YES;

    @synchronized (gForceLock) {
        gForceDocument = @{
            @"schema": @"watweaks_abprops_abt_force_full_v1",
            @"hook_installed": @YES,
            @"armed": @NO,
            @"applied": @NO,
            @"outcome": @"ready",
            @"constructor_class": kRequestClassName,
            @"constructor_selector": kRequestInitSelector,
            @"constructor_encoding": MethodEncoding(cls, selector),
            @"binary_evidence": @{
                @"initializer_va": @"0x003f58ec",
                @"config_hash_register": @"x4 -> x21",
                @"refresh_id_register": @"x5 -> x22",
                @"nil_config_hash_branch": @"cbz x21 @ 0x003f59a4",
                @"nil_refresh_id_branch": @"cbz x22 @ 0x003f59b4",
                @"interpretation": @"nil is an explicitly supported constructor path; each validator is conditionally omitted"
            }
        };
    }
    WAGRLogAppendF(@"[ABProps][ABTForceFull] exact constructor hook installed %@",
                   MethodEncoding(cls, selector));
    return YES;
}

BOOL WAGRABPropsABTLiveFetchForcedFull(id userContext,
                                       WAGRABPropsABTLiveCompletion completion,
                                       NSString **diagnostic) {
    EnsureForceState();
    if (!InstallForceHook()) {
        if (diagnostic) *diagnostic = @"XMPPRequestABProperties forced-full hook unavailable or ABI mismatch";
        return NO;
    }

    WAGRABPropsNativeSnapshot *before = WAGRABPropsReadNativeSnapshot(NULL);
    NSDictionary *metadata = before.metadata ?: @{};
    id beforeHash = metadata[@"hash"] ?: metadata[@"configHash"];
    id beforeRefresh = metadata[@"refreshID"] ?: metadata[@"refreshId"] ?: metadata[@"refresh_id"];

    @synchronized (gForceLock) {
        if (gForceArmed) {
            if (diagnostic) *diagnostic = @"another forced-full ABT request is still armed";
            return NO;
        }
        gForceArmed = YES;
        gForceApplied = NO;
        gForceArmTime = [NSDate date].timeIntervalSince1970;
        gForceTransactionToken = nil;
        gForceDocument = @{
            @"schema": @"watweaks_abprops_abt_force_full_v1",
            @"hook_installed": @YES,
            @"armed": @YES,
            @"applied": @NO,
            @"outcome": @"armed_waiting_request_constructor",
            @"armed_time": @(gForceArmTime),
            @"before_store": @{
                @"prop_count": @(before.numericPropCount),
                @"fingerprint": before.fingerprint ?: @"",
                @"config_hash": CompactValue(beforeHash),
                @"refresh_id": CompactValue(beforeRefresh)
            }
        };
    }

    __block BOOL sent = NO;
    sent = WAGRABPropsABTLiveFetch(userContext, ^(NSDictionary<NSString *,id> *result) {
        NSDictionary *force = WAGRABPropsABTForceFullDocument();
        @synchronized (gForceLock) {
            gForceArmed = NO;
            NSMutableDictionary *doc = [gForceDocument mutableCopy] ?: [NSMutableDictionary dictionary];
            if (!gForceApplied) {
                doc[@"armed"] = @NO;
                doc[@"outcome"] = @"native_transaction_completed_without_intercepting_constructor";
            } else {
                doc[@"outcome"] = @"forced_full_native_transaction_completed";
            }
            doc[@"completed_time"] = @([NSDate date].timeIntervalSince1970);
            gForceDocument = doc;
            force = [doc copy];
        }

        NSMutableDictionary *augmented = [result mutableCopy] ?: [NSMutableDictionary dictionary];
        augmented[@"request_mode"] = @"forced_full_without_config_hash_or_refresh_id";
        augmented[@"forced_full_request"] = force ?: @{};
        if (completion) completion(augmented);
    }, diagnostic);

    if (!sent) {
        @synchronized (gForceLock) {
            gForceArmed = NO;
            NSMutableDictionary *doc = [gForceDocument mutableCopy] ?: [NSMutableDictionary dictionary];
            doc[@"armed"] = @NO;
            doc[@"outcome"] = @"live_transaction_not_dispatched";
            gForceDocument = doc;
        }
        return NO;
    }

    if (diagnostic) {
        *diagnostic = @"forced-full ABT armed: native request will omit configHash and refreshID, then correlate handler/completion/store";
    }
    return YES;
}

NSDictionary<NSString *, id> *WAGRABPropsABTForceFullDocument(void) {
    EnsureForceState();
    @synchronized (gForceLock) {
        return [gForceDocument copy] ?: @{};
    }
}

__attribute__((constructor))
static void WAGRABPropsABTForceFullCtor(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ (void)InstallForceHook(); });
    }
}
