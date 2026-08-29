#pragma once

#import <Foundation/Foundation.h>
#import "WAGRABPropsABTLiveService.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Compatibility entry point for older diagnostics UI. It delegates to the one
/// correlated `full_empty_hash` service used by the ABT browser and Runtime Lab;
/// it owns no independent request, gate or timeout state.
BOOL WAGRABPropsABTLiveFetchForcedFull(id _Nullable userContext,
                                       WAGRABPropsABTLiveCompletion _Nullable completion,
                                       NSString * _Nullable * _Nullable diagnostic);

/// Runtime evidence and the latest transactional result.
NSDictionary<NSString *, id> *WAGRABPropsABTForceFullDocument(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
