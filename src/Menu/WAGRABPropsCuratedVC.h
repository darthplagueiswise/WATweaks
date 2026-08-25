#pragma once

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, WAGRABCuratedMode) {
    WAGRABCuratedModeEmployeeInternalDogfood = 0,
    WAGRABCuratedModeAura = 1,
    WAGRABCuratedModeLiquidGlass = 2,
};

@interface WAGRABPropsCuratedVC : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithMode:(WAGRABCuratedMode)mode;
@end
