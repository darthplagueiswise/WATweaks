#pragma once

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Resolves a MobileConfig name directly from the loaded FBMobileConfig schema.
/// This does not depend on id_name_mapping.json or on stable-ID resolution.
NSString * _Nullable WAGRMobileConfigRuntimeNameForSpecifier(uint64_t specifier);

/// Splits a runtime name such as "config.parameter" into its two components.
void WAGRMobileConfigRuntimeSplitName(NSString * _Nullable fullName,
                                      NSString * _Nullable * _Nullable configName,
                                      NSString * _Nullable * _Nullable parameterName);

/// Calls getStableIdFromParamSpecifier: on the account's live
/// userContext.mobileConfig manager first, then falls back to the bridge manager.
/// ABI is validated before the call and zero is returned when unresolved.
uint64_t WAGRMobileConfigRuntimeStableIdForSpecifier(id _Nullable userContext,
                                                      uint64_t specifier);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
