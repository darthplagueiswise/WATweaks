#import "WAGRABPropsABTLab.h"
#import "WAGRABPropsABTTransactionGate.h"
#import "WAGRLog.h"

static NSString * const kHistoryDefaultsKey = @"watweaks.abt_lab.history.v1";
static NSString * const kCustomDefaultsKey = @"watweaks.abt_lab.custom.v1";
static const NSUInteger kHistoryLimit = 24;

static NSObject *gLabLock;
static BOOL gLabBusy = NO;
static BOOL gMatrixRunning = NO;
static NSString *gMatrixToken;
static NSString *gLastMatrixToken;
static NSString *gLastMatrixOutcome;
static NSMutableArray<NSDictionary *> *gSessionResults;
static NSMutableArray<NSDictionary *> *gMatrixResults;
static NSDictionary *gLatestFullResult;

static void EnsureLabState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLabLock = [NSObject new];
        gSessionResults = [NSMutableArray array];
        gMatrixResults = [NSMutableArray array];
    });
}

static NSArray *PersistentHistory(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kHistoryDefaultsKey];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSDictionary *CompactResult(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *compact = [result mutableCopy];
    [compact removeObjectForKey:@"effective_snapshot"];

    NSDictionary *decoded = [compact[@"decoded_response"] isKindOfClass:NSDictionary.class]
        ? compact[@"decoded_response"] : nil;
    if (decoded) {
        NSMutableDictionary *summary = [decoded mutableCopy];
        [summary removeObjectForKey:@"props"];
        [summary removeObjectForKey:@"sampling_weights"];
        compact[@"decoded_response"] = summary;
    }
    return compact;
}

static NSDictionary *HistorySummary(NSDictionary *result) {
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"store_confirmation"] : @{};
    return @{
        @"time": @([NSDate date].timeIntervalSince1970),
        @"token": result[@"token"] ?: @"",
        @"matrix_token": result[@"matrix_token"] ?: @"",
        @"variant": result[@"variant"] ?: @"unknown",
        @"outcome": result[@"outcome"] ?: @"unknown",
        @"verified": @([result[@"verified"] boolValue]),
        @"wire_response_observed": @([result[@"wire_response_observed"] boolValue]),
        @"native_completion_observed": @([result[@"native_completion_observed"] boolValue]),
        @"wire_prop_count": result[@"wire_prop_count"] ?: @0,
        @"effective_prop_count": result[@"effective_prop_count"] ?: @0,
        @"fingerprint_changed": @([store[@"fingerprint_changed"] boolValue]),
        @"wire_attempt_count": @([result[@"wire_attempts"] count]),
        @"handler_attempt_count": @([result[@"handler_attempts"] count]),
        @"failure_attempt_count": @([result[@"did_fail_events"] count])
    };
}

static void RecordResult(NSDictionary *result) {
    EnsureLabState();
    NSDictionary *full = [result copy] ?: @{};
    NSDictionary *compact = CompactResult(full);
    @synchronized (gLabLock) {
        gLatestFullResult = full;
        [gSessionResults addObject:compact];
        if (gSessionResults.count > kHistoryLimit) {
            [gSessionResults removeObjectsInRange:NSMakeRange(0, gSessionResults.count - kHistoryLimit)];
        }
    }

    NSMutableArray *history = [PersistentHistory() mutableCopy];
    [history addObject:HistorySummary(full)];
    if (history.count > kHistoryLimit) {
        [history removeObjectsInRange:NSMakeRange(0, history.count - kHistoryLimit)];
    }
    [NSUserDefaults.standardUserDefaults setObject:history forKey:kHistoryDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static void RecordMatrixResult(NSString *matrixToken, NSDictionary *result) {
    EnsureLabState();
    @synchronized (gLabLock) {
        if (![gMatrixToken isEqualToString:matrixToken]) return;
        [gMatrixResults addObject:CompactResult(result ?: @{})];
    }
}

static NSDictionary *RejectedResult(NSString *variant, NSString *diagnostic) {
    return @{
        @"schema": @"watweaks_abprops_abt_live_service_v2",
        @"time": @([NSDate date].timeIntervalSince1970),
        @"variant": variant ?: @"unknown",
        @"outcome": @"preflight_or_dispatch_rejected",
        @"verified": @NO,
        @"diagnostic": diagnostic ?: @"request rejected before dispatch",
        @"wire_attempts": @[],
        @"did_fail_events": @[]
    };
}

NSArray<NSString *> *WAGRABPropsABTLabMatrixVariants(void) {
    // Non-mutating baselines first. The two full forms run last so the regular
    // and delta samples preserve the account's pre-test validators.
    return @[
        WAGRABPropsABTVariantRegularHash,
        WAGRABPropsABTVariantDeltaRefreshID,
        WAGRABPropsABTVariantFullNoValidators,
        WAGRABPropsABTVariantFullEmptyHash
    ];
}

BOOL WAGRABPropsABTLabIsBusy(void) {
    EnsureLabState();
    @synchronized (gLabLock) { return gLabBusy; }
}

BOOL WAGRABPropsABTLabRunVariant(NSString *variant,
                                 id userContext,
                                 WAGRABPropsABTLiveCompletion completion,
                                 NSString **diagnostic) {
    EnsureLabState();
    @synchronized (gLabLock) {
        if (gLabBusy) {
            if (diagnostic) *diagnostic = @"ABT Runtime Lab already has a pending transaction";
            return NO;
        }
        gLabBusy = YES;
        gMatrixRunning = NO;
    }

    __block WAGRABPropsABTLiveCompletion retainedCompletion = [completion copy];
    NSString *localDiagnostic = nil;
    BOOL invoked = WAGRABPropsABTLiveFetchVariant(variant, userContext,
        ^(NSDictionary<NSString *,id> *result) {
            RecordResult(result ?: @{});
            @synchronized (gLabLock) { gLabBusy = NO; }
            if (retainedCompletion) retainedCompletion(result ?: @{});
        }, &localDiagnostic);
    if (!invoked) {
        NSDictionary *rejected = RejectedResult(variant, localDiagnostic);
        RecordResult(rejected);
        @synchronized (gLabLock) { gLabBusy = NO; }
        if (diagnostic) *diagnostic = localDiagnostic ?: @"ABT variant was not dispatched";
        return NO;
    }
    if (diagnostic) *diagnostic = localDiagnostic ?: @"ABT transaction dispatched";
    return YES;
}

BOOL WAGRABPropsABTLabRunCustom(NSDictionary<NSString *, id> *configuration,
                                id userContext,
                                WAGRABPropsABTLiveCompletion completion,
                                NSString **diagnostic) {
    EnsureLabState();
    @synchronized (gLabLock) {
        if (gLabBusy) {
            if (diagnostic) *diagnostic = @"ABT Runtime Lab already has a pending transaction";
            return NO;
        }
        gLabBusy = YES;
        gMatrixRunning = NO;
    }

    __block WAGRABPropsABTLiveCompletion retainedCompletion = [completion copy];
    NSString *localDiagnostic = nil;
    BOOL invoked = WAGRABPropsABTLiveFetchCustom(configuration, userContext,
        ^(NSDictionary<NSString *,id> *result) {
            RecordResult(result ?: @{});
            @synchronized (gLabLock) { gLabBusy = NO; }
            if (retainedCompletion) retainedCompletion(result ?: @{});
        }, &localDiagnostic);
    if (!invoked) {
        NSDictionary *rejected = RejectedResult(WAGRABPropsABTVariantCustomWire,
                                                localDiagnostic);
        RecordResult(rejected);
        @synchronized (gLabLock) { gLabBusy = NO; }
        if (diagnostic) *diagnostic = localDiagnostic ?: @"custom ABT transaction was not dispatched";
        return NO;
    }
    if (diagnostic) *diagnostic = localDiagnostic ?: @"custom ABT transaction dispatched";
    return YES;
}

BOOL WAGRABPropsABTLabRunMatrix(id userContext,
                                WAGRABPropsABTLabProgress progress,
                                WAGRABPropsABTLiveCompletion completion,
                                NSString **diagnostic) {
    EnsureLabState();
    NSArray<NSString *> *variants = WAGRABPropsABTLabMatrixVariants();
    NSString *matrixToken = NSUUID.UUID.UUIDString;
    NSString *gateDiagnostic = nil;
    if (!WAGRABPropsABTTransactionAcquire(@"runtime_lab_matrix", matrixToken,
                                           &gateDiagnostic)) {
        if (diagnostic) *diagnostic = gateDiagnostic ?: @"another ABT transaction is active";
        return NO;
    }
    BOOL labWasBusy = NO;
    @synchronized (gLabLock) {
        labWasBusy = gLabBusy;
        if (!labWasBusy) {
            gLabBusy = YES;
            gMatrixRunning = YES;
            gMatrixToken = matrixToken;
            gLastMatrixToken = matrixToken;
            gLastMatrixOutcome = @"running";
            [gMatrixResults removeAllObjects];
        }
    }
    if (labWasBusy) {
        WAGRABPropsABTTransactionRelease(matrixToken);
        if (diagnostic) *diagnostic = @"ABT Runtime Lab already has a pending transaction";
        return NO;
    }

    __block WAGRABPropsABTLabProgress retainedProgress = [progress copy];
    __block WAGRABPropsABTLiveCompletion retainedCompletion = [completion copy];
    __block id retainedContext = userContext;
    __block void (^runAtIndex)(NSUInteger) = nil;
    runAtIndex = ^(NSUInteger index) {
        if (index >= variants.count) {
            BOOL currentMatrix = NO;
            @synchronized (gLabLock) {
                currentMatrix = [gMatrixToken isEqualToString:matrixToken];
                if (currentMatrix) {
                    gLabBusy = NO;
                    gMatrixRunning = NO;
                    gMatrixToken = nil;
                    gLastMatrixOutcome = @"completed";
                }
            }
            WAGRABPropsABTTransactionReleaseWhenIdle(matrixToken);
            if (!currentMatrix) { runAtIndex = nil; return; }
            NSDictionary *document = WAGRABPropsABTLabDocument(retainedContext);
            WAGRLogAppendF(@"[ABProps][ABTLab] matrix %@ completed variants=%lu",
                           matrixToken, (unsigned long)variants.count);
            if (retainedCompletion) retainedCompletion(document);
            runAtIndex = nil;
            return;
        }

        NSString *variant = variants[index];
        NSString *localDiagnostic = nil;
        BOOL invoked = WAGRABPropsABTLiveFetchVariantWithinTransaction(
            variant, retainedContext, matrixToken,
            ^(NSDictionary<NSString *,id> *result) {
                NSMutableDictionary *safeResult = [result mutableCopy] ?: [NSMutableDictionary dictionary];
                safeResult[@"matrix_token"] = matrixToken;
                BOOL timedOut = [safeResult[@"outcome"] isEqualToString:
                    @"timeout_waiting_exact_native_completion"];
                if (timedOut) safeResult[@"matrix_aborted_after_timeout"] = @YES;
                RecordResult(safeResult);
                RecordMatrixResult(matrixToken, safeResult);
                if (retainedProgress) retainedProgress(index + 1, variants.count, variant, safeResult);
                if (timedOut) {
                    BOOL currentMatrix = NO;
                    @synchronized (gLabLock) {
                        currentMatrix = [gMatrixToken isEqualToString:matrixToken];
                        if (currentMatrix) {
                            gLabBusy = NO;
                            gMatrixRunning = NO;
                            gMatrixToken = nil;
                            gLastMatrixOutcome = @"aborted_after_timeout";
                        }
                    }
                    WAGRABPropsABTTransactionReleaseWhenIdle(matrixToken);
                    if (!currentMatrix) { runAtIndex = nil; return; }
                    WAGRLogAppendF(@"[ABProps][ABTLab] matrix %@ aborted after timeout at %@; owner release deferred until native completion",
                                   matrixToken, variant ?: @"?");
                    NSDictionary *document = WAGRABPropsABTLabDocument(retainedContext);
                    if (retainedCompletion) retainedCompletion(document);
                    runAtIndex = nil;
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ runAtIndex(index + 1); });
            }, &localDiagnostic);
        if (!invoked) {
            NSMutableDictionary *rejected = [RejectedResult(variant, localDiagnostic) mutableCopy];
            rejected[@"matrix_token"] = matrixToken;
            RecordResult(rejected);
            RecordMatrixResult(matrixToken, rejected);
            if (retainedProgress) retainedProgress(index + 1, variants.count, variant, rejected);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ runAtIndex(index + 1); });
        }
    };

    WAGRLogAppendF(@"[ABProps][ABTLab] matrix %@ started variants=%lu",
                   matrixToken, (unsigned long)variants.count);
    dispatch_async(dispatch_get_main_queue(), ^{ runAtIndex(0); });
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"ABT matrix %@ started with %lu variants",
                       matrixToken, (unsigned long)variants.count];
    }
    return YES;
}

NSDictionary<NSString *, id> *WAGRABPropsABTLabDocument(id userContext) {
    EnsureLabState();
    NSArray *session = nil;
    NSArray *matrixResults = nil;
    NSDictionary *latest = nil;
    BOOL busy = NO, matrix = NO;
    NSString *matrixToken = nil, *lastMatrixToken = nil, *lastMatrixOutcome = nil;
    id savedCustom = [NSUserDefaults.standardUserDefaults objectForKey:kCustomDefaultsKey];
    if (![savedCustom isKindOfClass:NSDictionary.class]) savedCustom = @{};
    @synchronized (gLabLock) {
        session = [gSessionResults copy] ?: @[];
        latest = [gLatestFullResult copy] ?: WAGRABPropsABTLiveServiceDocument();
        matrixResults = [gMatrixResults copy] ?: @[];
        busy = gLabBusy;
        matrix = gMatrixRunning;
        matrixToken = [gMatrixToken copy];
        lastMatrixToken = [gLastMatrixToken copy];
        lastMatrixOutcome = [gLastMatrixOutcome copy];
    }
    return @{
        @"schema": @"watweaks_abprops_abt_runtime_lab_v1",
        @"generated_time": @([NSDate date].timeIntervalSince1970),
        @"scope": @"ABProps ABT only; MobileConfig is intentionally excluded from this checkpoint",
        @"busy": @(busy),
        @"matrix_running": @(matrix),
        @"matrix_token": matrixToken ?: @"",
        @"last_matrix_token": lastMatrixToken ?: @"",
        @"last_matrix_outcome": lastMatrixOutcome ?: @"not_run",
        @"matrix_order": WAGRABPropsABTLabMatrixVariants(),
        @"last_matrix_results_compact": matrixResults,
        @"saved_custom_configuration": savedCustom,
        @"capabilities": WAGRABPropsABTLiveCapabilityDocument(userContext),
        @"transaction_gate": WAGRABPropsABTTransactionGateDocument(),
        @"latest_full_result": latest ?: @{},
        @"live_service_state": WAGRABPropsABTLiveServiceDocument() ?: @{},
        @"session_results_compact": session,
        @"persistent_history": PersistentHistory(),
        @"session_log": WAGRLogSnapshot() ?: @""
    };
}

void WAGRABPropsABTLabClearHistory(void) {
    EnsureLabState();
    @synchronized (gLabLock) {
        [gSessionResults removeAllObjects];
        [gMatrixResults removeAllObjects];
        gLatestFullResult = nil;
        gLastMatrixToken = nil;
        gLastMatrixOutcome = nil;
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kHistoryDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    WAGRLogAppend(@"[ABProps][ABTLab] compact history cleared");
}
