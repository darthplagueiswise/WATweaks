#pragma once

#import <Foundation/Foundation.h>

@class WAGRABPropEntry;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the decimal WA/AB stable ID encoded by the getter trampoline itself.
/// This is independent of whether the active account currently has the ABProp in
/// gabp.*p, so Runtime rows can still show/search their real AB ID.
NSString * _Nullable WAGRABPropsCodeForTarget(NSString *className,
                                               NSString *selectorName,
                                               BOOL isClassMethod);
NSString * _Nullable WAGRABPropsCodeForEntry(WAGRABPropEntry *entry);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
