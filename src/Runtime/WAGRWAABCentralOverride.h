#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installs/refreshes the central WAProperties ABProps override bridge for a
/// descriptor-backed getter. This never patches the leaf getter itself.
BOOL WAGRWAABCentralOverrideInstallForTarget(NSString *className,
                                              NSString *selectorName,
                                              BOOL classMethod);

/// Rebuilds the stable-ID -> persisted-value cache after a store mutation.
void WAGRWAABCentralOverrideRefresh(void);

/// Re-applies the central bridge only when descriptor-backed ABProp overrides
/// are currently persisted. Safe to call from an explicit Apply action.
NSUInteger WAGRWAABCentralOverrideInstallPersisted(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
