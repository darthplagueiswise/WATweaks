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
BOOL WAGRABPropsNativeSetOverride(
    NSString *waStableID,
    id value,
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);
BOOL WAGRABPropsNativeClearOverride(
    NSString *waStableID,
    id _Nullable userContext,
    NSError * _Nullable * _Nullable outError,
    NSString * _Nullable * _Nullable outDiagnostic);

NSDictionary<NSString *, id> *WAGRABPropsNativeTrackedOverrides(void);
NSArray<NSNumber *> *WAGRABPropsNativeTrackedStableIDs(void);
NSInteger WAGRABPropsNativeSyncTrackedOverrides(
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);
NSInteger WAGRABPropsNativeClearTrackedOverrides(
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);
BOOL WAGRABPropsNativeRefreshMobileConfig(
    NSString *waStableID,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable outDiagnostic);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
