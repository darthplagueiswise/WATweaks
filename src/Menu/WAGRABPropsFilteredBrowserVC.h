#pragma once

#import "WAGRABPropsBrowserVC.h"

NS_ASSUME_NONNULL_BEGIN

/// Thin preset over the canonical live ABProps browser. The query is applied to
/// the browser after its UI is built; discovery/editing still comes exclusively
/// from the current Objective-C runtime and native ABProps cache.
@interface WAGRABPropsFilteredBrowserVC : WAGRABPropsBrowserVC
- (instancetype)initWithUserContext:(id _Nullable)userContext
                              query:(NSString *)query
                              title:(NSString *)title;
@end

NS_ASSUME_NONNULL_END
