#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves the decimal WA ABProp stable ID directly from the current ARM64
/// getter implementation/descriptor. Returns nil when the method is not a
/// descriptor-backed ABProp getter in the currently loaded build.
NSString * _Nullable WAGRABPropsStableIDForTarget(NSString *className,
                                                   NSString *selectorName,
                                                   BOOL classMethod);

NS_ASSUME_NONNULL_END
