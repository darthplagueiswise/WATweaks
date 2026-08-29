#import "WAGRABPropsABTForceFull.h"
#import "WAGRABPropsABTLiveService.h"
#import "WAGRLog.h"

// Compatibility entry point retained for the diagnostics controller. There is
// deliberately no second request implementation or transaction state here:
// browser, Runtime Lab and diagnostics all use the same correlated
// full_empty_hash service and its exact request/handler/store proof.

static NSObject *gForceAdapterLock;
static NSDictionary<NSString *, id> *gForceAdapterDocument;

static void EnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gForceAdapterLock = [NSObject new];
        gForceAdapterDocument = @{
            @"schema": @"watweaks_abprops_abt_force_full_adapter_v3",
            @"outcome": @"not_run",
            @"delegates_to": WAGRABPropsABTVariantFullEmptyHash,
            @"hook_installed": @NO,
            @"pending": @NO
        };
    });
}

static void Publish(NSDictionary<NSString *, id> *document) {
    EnsureState();
    @synchronized (gForceAdapterLock) {
        gForceAdapterDocument = [document copy] ?: @{};
    }
}

BOOL WAGRABPropsABTLiveFetchForcedFull(id userContext,
                                       WAGRABPropsABTLiveCompletion completion,
                                       NSString **diagnostic) {
    EnsureState();
    __block WAGRABPropsABTLiveCompletion retainedCompletion = [completion copy];
    NSString *serviceDiagnostic = nil;
    Publish(@{
        @"schema": @"watweaks_abprops_abt_force_full_adapter_v3",
        @"outcome": @"dispatching",
        @"delegates_to": WAGRABPropsABTVariantFullEmptyHash,
        @"hook_installed": @NO,
        @"pending": @YES,
        @"verified": @NO
    });
    BOOL invoked = WAGRABPropsABTLiveFetchVariant(
        WAGRABPropsABTVariantFullEmptyHash, userContext,
        ^(NSDictionary<NSString *, id> *result) {
            NSMutableDictionary *document = [result mutableCopy] ?: [NSMutableDictionary dictionary];
            NSString *proof = nil;
            BOOL verified = WAGRABPropsABTVerifiedFullEmptyHashResult(result ?: @{}, &proof);
            document[@"schema"] = @"watweaks_abprops_abt_force_full_adapter_v3";
            document[@"delegates_to"] = WAGRABPropsABTVariantFullEmptyHash;
            document[@"strict_full_proof"] = @(verified);
            document[@"strict_full_proof_diagnostic"] = proof ?: @"";
            document[@"hook_installed"] = @NO;
            document[@"pending"] = @NO;
            Publish(document);
            WAGRLogAppendF(@"[ABProps][ABTForceFullAdapter] verified=%@ outcome=%@",
                           verified ? @"YES" : @"NO", document[@"outcome"] ?: @"?");
            if (retainedCompletion) retainedCompletion([document copy]);
        }, &serviceDiagnostic);
    if (!invoked) {
        Publish(@{
            @"schema": @"watweaks_abprops_abt_force_full_adapter_v3",
            @"outcome": @"preflight_or_dispatch_rejected",
            @"delegates_to": WAGRABPropsABTVariantFullEmptyHash,
            @"diagnostic": serviceDiagnostic ?: @"correlated full fetch was rejected",
            @"hook_installed": @NO,
            @"pending": @NO,
            @"verified": @NO
        });
        if (diagnostic) *diagnostic = serviceDiagnostic ?: @"correlated full fetch was rejected";
        return NO;
    }
    if (diagnostic) *diagnostic = serviceDiagnostic ?: @"correlated full fetch dispatched";
    return YES;
}

NSDictionary<NSString *, id> *WAGRABPropsABTForceFullDocument(void) {
    EnsureState();
    @synchronized (gForceAdapterLock) {
        return [gForceAdapterDocument copy] ?: @{};
    }
}
