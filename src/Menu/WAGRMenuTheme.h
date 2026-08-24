#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIColor *WAGRMenuBackgroundColor(void);
UIColor *WAGRMenuCellColor(void);
UIColor *WAGRMenuSecondaryCellColor(void);
UIColor *WAGRMenuTextColor(void);
UIColor *WAGRMenuSecondaryTextColor(void);
UIColor *WAGRMenuSeparatorColor(void);
UIColor *WAGRMenuAccentForIndex(NSInteger index);
UIColor *WAGRMenuAccentForKey(NSString * _Nullable key, NSInteger fallbackIndex);
UIFont *WAGRMenuTitleFont(void);
UIFont *WAGRMenuDetailFont(void);
UIFont *WAGRMenuRuntimeTitleFont(void);
UIFont *WAGRMenuRuntimeDetailFont(void);
void WAGRMenuApplyTableStyle(UITableView * _Nullable tableView, UIViewController * _Nullable owner);
void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString * _Nullable key);

/// Applies real UIKit Liquid Glass to the public UISearchBar chrome on iOS 26+.
/// The search text field and scope UISegmentedControl receive UIGlassEffect;
/// scrolling content rows intentionally remain ordinary inset-grouped cells.
void WAGRMenuApplySearchGlass(UISearchBar * _Nullable searchBar);

UIImage * _Nullable WAGRMenuSymbol(NSString * _Nullable name, UIColor * _Nullable tint);
BOOL WAGRMenuIsNegativeGateName(NSString * _Nullable name);

NS_ASSUME_NONNULL_END
