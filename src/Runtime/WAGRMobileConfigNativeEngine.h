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

/// Invalidates the account-scoped MobileConfig context using ABI-safe native
/// Objective-C entrypoints. This is a LOCAL invalidation, not a server fetch.
BOOL WAGRMobileConfigNativeInvalidate(id _Nullable userContext,
                                      NSString * _Nullable * _Nullable outDiagnostic);

typedef void (^WAGRMobileConfigNativeFetchCompletion)(NSDictionary<NSString *, id> *result);

/// Requests the normal authenticated MobileConfig fetch through the WhatsApp
/// account pipeline: WAContextMain.chatManager -> fetchMobileConfig:NO. The
/// result correlates the native XWA2/WWW input observer with the XWA2 response
/// and WAMobileConfigLastFetchStore success markers plus the account-scoped latest-config file state. No synthetic GraphQL
/// input or token is constructed by WATweaks.
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
