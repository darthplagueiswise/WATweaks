#pragma once
#import <UIKit/UIKit.h>
#import "../Runtime/WAGRSurface.h"

@interface WAGRSurfaceBrowserVC : UITableViewController <UISearchResultsUpdating, UISearchBarDelegate>
- (instancetype)initWithSpec:(WAGRSurfaceSpec *)spec;
@end
