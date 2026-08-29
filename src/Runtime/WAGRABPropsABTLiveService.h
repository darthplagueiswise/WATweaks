#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WAGRABPropsABTLiveCompletion)(NSDictionary<NSString *, id> *result);

FOUNDATION_EXPORT NSString * const WAGRABPropsABTVariantRegularHash;
FOUNDATION_EXPORT NSString * const WAGRABPropsABTVariantDeltaRefreshID;
FOUNDATION_EXPORT NSString * const WAGRABPropsABTVariantFullEmptyHash;
FOUNDATION_EXPORT NSString * const WAGRABPropsABTVariantFullNoValidators;
FOUNDATION_EXPORT NSString * const WAGRABPropsABTVariantCustomWire;

#ifdef __cplusplus
extern "C" {
#endif

/// Performs one explicit account-scoped ABT transaction through WhatsApp's live
/// XMPPConnectionABPropsRequestManager. The callback receives either the fully
/// correlated native result or an explicit timeout result. A timeout is
/// terminal for WATweaks correlation and releases the ABT gate; any later native
/// completion is still forwarded to WhatsApp but cannot mutate the published
/// result or block a subsequent explicit transaction.
BOOL WAGRABPropsABTLiveFetch(id _Nullable userContext,
                             WAGRABPropsABTLiveCompletion _Nullable completion,
                             NSString * _Nullable * _Nullable diagnostic);

/// Runs one of the four protocol shapes proven by the supplied SharedModules
/// binary. The no-validator form uses an explicit one-shot initializer argument
/// override; it is never armed outside the correlated transaction.
BOOL WAGRABPropsABTLiveFetchVariant(NSString *variant,
                                    id _Nullable userContext,
                                    WAGRABPropsABTLiveCompletion _Nullable completion,
                                    NSString * _Nullable * _Nullable diagnostic);

/// Matrix-only form. `ownerToken` must already own the process-wide ABT gate;
/// every variant is registered as its child so the matrix remains isolated even
/// during the short delay between variants.
BOOL WAGRABPropsABTLiveFetchVariantWithinTransaction(
    NSString *variant,
    id _Nullable userContext,
    NSString *ownerToken,
    WAGRABPropsABTLiveCompletion _Nullable completion,
    NSString * _Nullable * _Nullable diagnostic);

/// Sends one runtime-defined wire shape. Supported validator policies are
/// `native`, `nil`, `empty`, `zero` and `custom`. Custom strings are limited to
/// 256 characters and the timeout is clamped to 45...120 seconds so it cannot
/// undercut the native 2/4-attempt retry window observed in this build.
BOOL WAGRABPropsABTLiveFetchCustom(
    NSDictionary<NSString *, id> *configuration,
    id _Nullable userContext,
    WAGRABPropsABTLiveCompletion _Nullable completion,
    NSString * _Nullable * _Nullable diagnostic);

/// Read-only ABI, object-route and current-validator preflight used by the lab UI.
NSDictionary<NSString *, id> *WAGRABPropsABTLiveCapabilityDocument(
    id _Nullable userContext);

/// Last correlated explicit transaction. Unlike the general ABT observer this
/// document is never replaced by unrelated/background ABProps traffic.
NSDictionary<NSString *, id> *WAGRABPropsABTLiveServiceDocument(void);

/// Exact account snapshot resolved through WAProperties._propertiesStore.
NSDictionary<NSString *, id> * _Nullable WAGRABPropsABTAccountSnapshotDocument(
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError);

/// Strict server/IQ/handler/exact-store gate for the production full path.
BOOL WAGRABPropsABTVerifiedFullEmptyHashResult(
    NSDictionary<NSString *, id> *result,
    NSString * _Nullable * _Nullable diagnostic);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
