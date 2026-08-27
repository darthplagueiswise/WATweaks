#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Resolves one WA ABProp stable ID through the production path that is live in
/// the current WhatsApp build:
/// WA stable ID -> WAMCEvaluation paramSpecifier -> exact account-scoped
/// FBMobileConfigUserSessionContextManager -> external config stable ID.
/// Returns nil unless every identity required by mc_overrides is proven.
NSDictionary<NSString *, id> * _Nullable WAGRABPropsNativeOverrideMapping(
    NSString *waStableID,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Returns the raw mc_overrides row currently persisted for this ABProp, or nil
/// when no native MobileConfig override exists.
NSString * _Nullable WAGRABPropsNativeOverrideRow(
    NSString *waStableID,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Persists one ABProp value through the native MobileConfig override table and
/// requests the app's ABI-safe context invalidation. RuntimeValueStore/swizzling
/// is intentionally not used here.
BOOL WAGRABPropsNativeSetOverride(
    NSString *waStableID,
    id value,
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Removes only this ABProp's native MobileConfig row, preserving all unrelated
/// entries in mc_overrides.json, then invalidates the live UserSession context.
BOOL WAGRABPropsNativeClearOverride(
    NSString *waStableID,
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
