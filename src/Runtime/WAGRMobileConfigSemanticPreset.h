#pragma once

#import <Foundation/Foundation.h>
#import "WAGRMobileConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Builds the Internal / Employee / Dogfood / Fishfood / Bug Report / Rage Shake
/// preset from the current-build AB catalogue and the already-resolved live
/// FBMobileConfig UserSession mappings.
///
/// Output deliberately matches the physical mc_overrides grammar observed in the
/// supplied native example:
///   "<external config/admin id>:": ["<parameter index>: : <typed value>"]
/// Names are kept in the validation report rather than injected into the wire
/// grammar. No localConfigIndex or compact parameter token is used as a key.
NSDictionary<NSString *, NSArray<NSString *> *> * _Nullable
WAGRMobileConfigInternalPresetDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id _Nullable userContext,
    NSDictionary<NSString *, id> * _Nullable * _Nullable validationReport,
    NSError * _Nullable * _Nullable outError);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
