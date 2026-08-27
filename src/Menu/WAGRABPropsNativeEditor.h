#pragma once

#import <UIKit/UIKit.h>
#import "../Runtime/WAGRABPropsRuntime.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Presents the ABProps editor whose primary Apply path is the exact live
/// UserSession MobileConfig override table. runtimeFallback is surfaced only as
/// an explicitly labelled experimental option when no native crosswalk exists.
void WAGRPresentABPropsNativeEditor(UIViewController *presenter,
                                    UIView * _Nullable sourceView,
                                    WAGRABPropEntry *entry,
                                    NSArray *runtimeObjects,
                                    id _Nullable userContext,
                                    NSString * _Nullable stableIDHint,
                                    dispatch_block_t _Nullable runtimeFallback,
                                    dispatch_block_t _Nullable completion);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
