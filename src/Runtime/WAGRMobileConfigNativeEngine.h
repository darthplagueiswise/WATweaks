#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Legacy compatibility API retained for binary/source compatibility only.
/// It is intentionally BLOCKED: WATweaks will not synthesize or atomically
/// write mc_overrides.json until the native FBMobileConfigOverridesTable C++
/// serializer is proven and callable with its real ABI.
BOOL WAGRMobileConfigNativeWriteOverrideDocument(
    NSDictionary<NSString *, id> *document,
    id _Nullable userContext,
    BOOL mergeExisting,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Invalidates the account-scoped cached latest context using the validated
/// native selector. Does not call forceInvalidate, which tears down the manager.
BOOL WAGRMobileConfigNativeInvalidate(id _Nullable userContext,
                                      NSString * _Nullable * _Nullable outDiagnostic);

typedef void (^WAGRMobileConfigNativeFetchCompletion)(NSDictionary<NSString *, id> *result);

/// Requests the normal authenticated MobileConfig fetch through the WhatsApp
/// account pipeline. WhatsApp 26.40 uses fetchMobileConfig:NO stack:-1; older
/// supported single-BOOL entrypoints remain a fallback. Success requires a native
/// LastFetchStore marker matching the captured preferences store, unit type and
/// unit ID. XWA2/WWW route, native input fields and file state are passive
/// diagnostics. Observer availability never gates dispatch. No GraphQL input,
/// query hash, credential, token or eligibility is constructed by WATweaks.
BOOL WAGRMobileConfigNativeFetchAccount(id _Nullable userContext,
                                        WAGRMobileConfigNativeFetchCompletion _Nullable completion,
                                        NSString * _Nullable * _Nullable outDiagnostic);

NSDictionary<NSString *, id> *WAGRMobileConfigNativeFetchState(void);
NSDictionary<NSString *, id> *WAGRMobileConfigNativeEngineDiagnosticDocument(id _Nullable userContext);
NSString *WAGRMobileConfigNativeEngineDiagnosticText(id _Nullable userContext);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
