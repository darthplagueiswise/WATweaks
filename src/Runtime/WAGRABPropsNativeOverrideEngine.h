#pragma once

#import <Foundation/Foundation.h>
#include <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

NSDictionary<NSString *, id> * _Nullable WAGRABPropsNativeOverrideMapping(
    NSString *waStableID,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);
NSString * _Nullable WAGRABPropsNativeOverrideRow(
    NSString *waStableID,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Applies one ABProp through the native ABProp -> WAMCEvaluation ->
/// FBMobileConfigStartupConfigs path. Success requires all of the following:
/// 1) the native setter accepts the typed value, 2) configValuesOverride reads
/// it back, 3) FBMobileConfigStartupConfigsOverride reads it back from the
/// native App Group defaults, and 4) the account-scoped typed MobileConfig
/// getter returns the same effective value after invalidation. Any mismatch is
/// rolled back and reported as failure. This function never writes
/// mc_overrides.json.
BOOL WAGRABPropsNativeSetOverride(
    NSString *waStableID,
    id value,
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Removes one native StartupConfigs override and verifies that it disappeared
/// from both the live dictionary and its App Group backing store.
BOOL WAGRABPropsNativeClearOverride(
    NSString *waStableID,
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

NSDictionary<NSString *, id> *WAGRABPropsNativeTrackedOverrides(void);
NSArray<NSNumber *> *WAGRABPropsNativeTrackedStableIDs(void);
void WAGRABPropsNativeRememberTrackedOverride(NSString *waStableID, id value);
void WAGRABPropsNativeForgetTrackedOverride(NSString *waStableID);
void WAGRABPropsNativeForgetAllTrackedOverrides(void);
NSInteger WAGRABPropsNativeSyncTrackedOverrides(
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);
NSInteger WAGRABPropsNativeClearTrackedOverrides(
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Local targeted context refresh only. This is not a server fetch.
BOOL WAGRABPropsNativeRefreshMobileConfig(
    NSString *waStableID,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);

/// Read-only export of the native StartupConfigs override state: the live
/// configValuesOverride dictionary plus every
/// FBMobileConfigStartupConfigsOverride* entry from the exact native
/// sharedUserDefaultsForTesting App Group store.
NSDictionary<NSString *, id> *WAGRABPropsNativeStartupOverrideStoreDocument(void);

/// Emits only WATweaks-tracked ABProp overrides that are still verified in the
/// native App Group store AND as the account-scoped effective MobileConfig
/// value, translated into the mc_overrides JSON grammar. This is a custom
/// export for interoperability; it does not write the physical C++ table.
NSDictionary<NSString *, id> *WAGRABPropsNativeMCOverridesExportDocument(
    id _Nullable userContext,
    NSDictionary<NSString *, id> * _Nullable * _Nullable stats);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
