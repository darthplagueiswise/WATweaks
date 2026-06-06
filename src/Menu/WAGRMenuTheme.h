#pragma once
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL WAGRIsIOS26OrNewer(void);
UIVisualEffect *WAGRRealLiquidGlassEffect(BOOL clearStyle, BOOL interactive, UIColor *tintColor);
UIColor *WAGRGlassBaseSurfaceColor(void);
UIColor *WAGRGlassReadableFillColor(void);
UIColor *WAGRMenuBackgroundColor(void);
UIColor *WAGRMenuCellColor(void);
UIColor *WAGRMenuSecondaryCellColor(void);
UIColor *WAGRMenuTextColor(void);
UIColor *WAGRMenuSecondaryTextColor(void);
UIColor *WAGRMenuSeparatorColor(void);
UIColor *WAGRMenuAccentForIndex(NSInteger index);
UIColor *WAGRMenuAccentForKey(NSString *key, NSInteger fallbackIndex);
UIFont *WAGRMenuTitleFont(void);
UIFont *WAGRMenuDetailFont(void);
UIFont *WAGRMenuRuntimeTitleFont(void);
UIFont *WAGRMenuRuntimeDetailFont(void);
void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner);
void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key);
void WAGRApplyGlassBackdropToViewController(UIViewController *vc);
void WAGRApplyLiquidGlassToViewTree(UIView *root);
void WAGRStyleSearchBarForGlass(UISearchBar *searchBar);
void WAGRApplyGlassToButton(UIButton *button, BOOL prominent);
UIImage *WAGRMenuSymbol(NSString *name, UIColor *tint);
BOOL WAGRMenuIsNegativeGateName(NSString *name);

#ifdef __cplusplus
}
#endif
