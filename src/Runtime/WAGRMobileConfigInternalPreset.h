#pragma once

#import <Foundation/Foundation.h>
#import "WAGRMobileConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Builds the Employee/Internal/Dogfood/Debug/BugReport/RageShake/Test/Fishfood
/// preset exclusively from already-resolved user-session MobileConfig mappings.
/// The returned document uses FBMobileConfig's native mc_overrides grammar and
/// never substitutes WA stable IDs for external config/admin IDs.
NSDictionary<NSString *, NSArray<NSString *> *> *WAGRMobileConfigInternalPresetDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    NSDictionary<NSString *, id> * _Nullable * _Nullable stats);

/// Human-readable description of the semantic selector policy used by the
/// resolver-driven preset. Useful for the export UI/diagnostics.
NSString *WAGRMobileConfigInternalPresetPolicyDescription(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END