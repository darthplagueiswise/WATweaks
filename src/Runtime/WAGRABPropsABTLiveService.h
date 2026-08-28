#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WAGRABPropsABTLiveCompletion)(NSDictionary<NSString *, id> *result);

#ifdef __cplusplus
extern "C" {
#endif

/// Performs one explicit account-scoped ABT transaction through WhatsApp's live
/// XMPPConnectionABPropsRequestManager and completes only when the exact native
/// completion passed to requestFreshABProps has fired.
BOOL WAGRABPropsABTLiveFetch(id _Nullable userContext,
                             WAGRABPropsABTLiveCompletion _Nullable completion,
                             NSString * _Nullable * _Nullable diagnostic);

/// Last correlated explicit transaction. Unlike the general ABT observer this
/// document is never replaced by unrelated/background ABProps traffic.
NSDictionary<NSString *, id> *WAGRABPropsABTLiveServiceDocument(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
