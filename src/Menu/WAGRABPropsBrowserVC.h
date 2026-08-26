#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRABPropsBrowserVC : UITableViewController <UISearchResultsUpdating, UISearchBarDelegate>
- (instancetype)initWithUserContext:(id _Nullable)userContext;

/// Reuses the exact ABProperties browser/runtime store while presenting a
/// feature-focused view. `initialQuery` is only a UI filter; it does not create
/// a second catalog or a second persistence layer.
- (instancetype)initWithUserContext:(id _Nullable)userContext
                       initialQuery:(NSString * _Nullable)initialQuery
                              title:(NSString * _Nullable)title;
@end

NS_ASSUME_NONNULL_END
