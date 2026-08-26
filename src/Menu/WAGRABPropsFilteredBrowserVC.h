#pragma once

#import "WAGRABPropsBrowserVC.h"

NS_ASSUME_NONNULL_BEGIN

@interface WAGRABPropsFilteredBrowserVC : WAGRABPropsBrowserVC
- (instancetype)initWithUserContext:(id _Nullable)userContext
                              query:(NSString *)query
                              title:(NSString *)title;
@end

NS_ASSUME_NONNULL_END
