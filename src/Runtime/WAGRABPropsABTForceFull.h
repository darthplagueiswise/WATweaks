#pragma once

#import <Foundation/Foundation.h>
#import "WAGRABPropsABTLiveService.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Runs a hook-free, account-scoped native full-fetch transaction. It invokes
/// the active -[WAProperties resetConfigHashToEmptyString] pair and then calls
/// -[XMPPConnectionABPropsRequestManager requestFreshABProps:NO ...]. Success is
/// reported only when native completion fires and that exact WAProperties
/// object has a non-empty configHash again; dispatch alone is not success.
BOOL WAGRABPropsABTLiveFetchForcedFull(id _Nullable userContext,
                                       WAGRABPropsABTLiveCompletion _Nullable completion,
                                       NSString * _Nullable * _Nullable diagnostic);

/// Runtime evidence and the latest transactional result.
NSDictionary<NSString *, id> *WAGRABPropsABTForceFullDocument(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
