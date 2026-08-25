#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

BOOL WAGRRuntimeValueLooksLikeJSON(id _Nullable value);

/// Presents a full-screen JSON editor while preserving the getter's Foundation
/// return kind. NSString JSON remains NSString; NSDictionary/NSArray remain
/// their original collection type.
void WAGRPresentRuntimeJSONEditor(UIViewController *presenter,
                                  NSString *title,
                                  NSString *className,
                                  NSString *selectorName,
                                  BOOL isClassMethod,
                                  NSString *typeCode,
                                  id currentValue,
                                  dispatch_block_t _Nullable completion);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
