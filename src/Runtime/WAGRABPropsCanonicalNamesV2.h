#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Lazily builds the current-build ABProp code -> canonical Objective-C getter map
/// by decoding the native getter descriptors. This is read-only: it never patches
/// executable pages and is therefore safe for sideloaded/code-signed builds.
NSString * _Nullable WAGRABPropsCanonicalNameForCode(NSString *code);
NSUInteger WAGRABPropsCanonicalNameCount(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
