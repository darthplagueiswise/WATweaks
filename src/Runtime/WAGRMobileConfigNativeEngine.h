#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Merges/writes a valid mc_overrides dictionary at the path owned by the exact
/// account-scoped UserSession manager, then requests native context invalidation.
/// Returns NO without writing when UserSession/path/JSON validation fails.
BOOL WAGRMobileConfigNativeWriteOverrideDocument(
    NSDictionary<NSString *, id> *document,
    id _Nullable userContext,
    BOOL mergeExisting,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Requests the reload/invalidation hooks that are ABI-safe in the current
/// Objective-C surface. No C++ shared_ptr method is invoked from Objective-C.
BOOL WAGRMobileConfigNativeInvalidate(id _Nullable userContext,
                                      NSString * _Nullable * _Nullable outDiagnostic);

NSDictionary<NSString *, id> *WAGRMobileConfigNativeEngineDiagnosticDocument(
    id _Nullable userContext);
NSString *WAGRMobileConfigNativeEngineDiagnosticText(id _Nullable userContext);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
