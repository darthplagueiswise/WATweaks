#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

BOOL WAGRABPropsABTTransactionAcquire(NSString *channel,
                                      NSString *token,
                                      NSString * _Nullable * _Nullable diagnostic);
BOOL WAGRABPropsABTTransactionAcquireWithin(NSString *channel,
                                            NSString *token,
                                            NSString *ownerToken,
                                            NSString * _Nullable * _Nullable diagnostic);
void WAGRABPropsABTTransactionRelease(NSString *token);
void WAGRABPropsABTTransactionReleaseWhenIdle(NSString *ownerToken);
NSDictionary<NSString *, id> *WAGRABPropsABTTransactionGateDocument(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
