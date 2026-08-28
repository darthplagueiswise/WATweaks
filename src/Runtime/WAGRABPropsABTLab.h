#pragma once

#import <Foundation/Foundation.h>
#import "WAGRABPropsABTLiveService.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^WAGRABPropsABTLabProgress)(NSUInteger completed,
                                          NSUInteger total,
                                          NSString *variant,
                                          NSDictionary<NSString *, id> *result);

#ifdef __cplusplus
extern "C" {
#endif

NSArray<NSString *> *WAGRABPropsABTLabMatrixVariants(void);

BOOL WAGRABPropsABTLabRunVariant(NSString *variant,
                                 id _Nullable userContext,
                                 WAGRABPropsABTLiveCompletion _Nullable completion,
                                 NSString * _Nullable * _Nullable diagnostic);

BOOL WAGRABPropsABTLabRunCustom(NSDictionary<NSString *, id> *configuration,
                                id _Nullable userContext,
                                WAGRABPropsABTLiveCompletion _Nullable completion,
                                NSString * _Nullable * _Nullable diagnostic);

BOOL WAGRABPropsABTLabRunMatrix(id _Nullable userContext,
                                WAGRABPropsABTLabProgress _Nullable progress,
                                WAGRABPropsABTLiveCompletion _Nullable completion,
                                NSString * _Nullable * _Nullable diagnostic);

BOOL WAGRABPropsABTLabIsBusy(void);
NSDictionary<NSString *, id> *WAGRABPropsABTLabDocument(id _Nullable userContext);
void WAGRABPropsABTLabClearHistory(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
