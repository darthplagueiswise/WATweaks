#pragma once
#import <UIKit/UIKit.h>

// Root browser whose categories are rebuilt from the Objective-C classes and
// zero-argument typed getters loaded in the current WhatsApp process.
@interface WAGRRuntimeGatesVC : UITableViewController <UISearchResultsUpdating>
@end
