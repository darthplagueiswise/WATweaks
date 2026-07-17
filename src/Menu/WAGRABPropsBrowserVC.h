#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRABPropsBrowserVC : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithUserContext:(nullable id)userContext;
@end

NS_ASSUME_NONNULL_END
