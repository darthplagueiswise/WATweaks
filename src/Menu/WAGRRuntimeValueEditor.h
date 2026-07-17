#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

void WAGRPresentRuntimeValueEditor(UIViewController *presenter,
                                   UIView * _Nullable sourceView,
                                   NSString *className,
                                   NSString *selectorName,
                                   BOOL isClassMethod,
                                   NSString *typeCode,
                                   NSString *currentDescription,
                                   id _Nullable currentRawValue,
                                   dispatch_block_t _Nullable completion);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
