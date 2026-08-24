#import "WAGRMenuTheme.h"

UIColor *WAGRMenuBackgroundColor(void) {
    return UIColor.blackColor;
}

UIColor *WAGRMenuCellColor(void) {
    // WhatsApp dark settings cards are neutral, not accent-tinted.
    return [UIColor colorWithWhite:0.095 alpha:1.0];
}

UIColor *WAGRMenuSecondaryCellColor(void) {
    return [UIColor colorWithWhite:0.095 alpha:1.0];
}

UIColor *WAGRMenuTextColor(void) {
    return UIColor.whiteColor;
}

UIColor *WAGRMenuSecondaryTextColor(void) {
    return [UIColor colorWithWhite:0.62 alpha:1.0];
}

UIColor *WAGRMenuSeparatorColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.10];
}

// Menu chrome/content is deliberately neutral, like WhatsApp Settings.
// Semantic state remains on native controls (UISwitch green), destructive text
// and explicit diagnostics; category names must not paint every icon differently.
UIColor *WAGRMenuAccentForIndex(__unused NSInteger index) {
    return UIColor.whiteColor;
}

UIColor *WAGRMenuAccentForKey(__unused NSString *key, __unused NSInteger fallbackIndex) {
    return UIColor.whiteColor;
}

UIFont *WAGRMenuTitleFont(void) {
    UIFont *preferred = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    return [UIFont systemFontOfSize:MAX(17.0, preferred.pointSize)
                             weight:UIFontWeightRegular];
}

UIFont *WAGRMenuDetailFont(void) {
    UIFont *preferred = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    return [UIFont systemFontOfSize:MAX(13.0, preferred.pointSize)
                             weight:UIFontWeightRegular];
}

UIFont *WAGRMenuRuntimeTitleFont(void) {
    UIFont *preferred = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    return [UIFont systemFontOfSize:MAX(16.0, preferred.pointSize)
                             weight:UIFontWeightRegular];
}

UIFont *WAGRMenuRuntimeDetailFont(void) {
    UIFont *preferred = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    return [UIFont systemFontOfSize:MAX(13.0, preferred.pointSize)
                             weight:UIFontWeightRegular];
}

static UIView *WAGRMenuFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = WAGRMenuFindSubviewOfClass(child, cls);
        if (found) return found;
    }
    return nil;
}

void WAGRMenuApplySearchGlass(UISearchBar *searchBar) {
    if (!searchBar) return;
    searchBar.tintColor = UIColor.whiteColor;

    if (@available(iOS 26.0, *)) {
        // UIKit already supplies UIGlassEffectStyleRegular-style navigation/search
        // chrome on iOS 26+. Never add a second glass view inside searchTextField.
        UITextField *field = searchBar.searchTextField;
        field.textColor = UIColor.whiteColor;
        field.tintColor = UIColor.whiteColor;
        field.leftView.tintColor = [UIColor colorWithWhite:0.90 alpha:1.0];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;

        UISegmentedControl *scope = (UISegmentedControl *)WAGRMenuFindSubviewOfClass(searchBar, UISegmentedControl.class);
        if (scope) {
            [scope setTitleTextAttributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.82 alpha:1.0],
                NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular]
            } forState:UIControlStateNormal];
            [scope setTitleTextAttributes:@{
                NSForegroundColorAttributeName: UIColor.whiteColor,
                NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium]
            } forState:UIControlStateSelected];
        }
    } else {
        searchBar.barStyle = UIBarStyleBlack;
        searchBar.barTintColor = UIColor.blackColor;
        searchBar.backgroundColor = UIColor.blackColor;
        if (@available(iOS 13.0, *)) {
            UITextField *field = searchBar.searchTextField;
            field.textColor = UIColor.whiteColor;
            field.tintColor = UIColor.whiteColor;
            field.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
            field.leftView.tintColor = [UIColor colorWithWhite:0.90 alpha:1.0];
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }
    }
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (tableView) {
        tableView.backgroundView = nil;
        tableView.backgroundColor = UIColor.blackColor;
        tableView.separatorColor = WAGRMenuSeparatorColor();
        tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
        // Do not collapse inset-grouped section spacing globally. UIKit's grouped
        // geometry is part of the native WhatsApp Settings hierarchy.
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 0.0;
    }

    if (owner) {
        if (@available(iOS 13.0, *)) owner.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        owner.view.backgroundColor = UIColor.blackColor;
        UINavigationBar *bar = owner.navigationController.navigationBar;
        bar.tintColor = UIColor.whiteColor;
        bar.translucent = YES;

        if (@available(iOS 26.0, *)) {
            // Native UINavigationBar / UIBarButtonItem Liquid Glass.
        } else if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
            [appearance configureWithOpaqueBackground];
            appearance.backgroundColor = UIColor.blackColor;
            appearance.shadowColor = WAGRMenuSeparatorColor();
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
            bar.standardAppearance = appearance;
            bar.scrollEdgeAppearance = appearance;
            bar.compactAppearance = appearance;
        }
    }
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, __unused NSInteger index, __unused NSString *key) {
    if (!cell) return;
    cell.backgroundView = nil;
    cell.backgroundColor = WAGRMenuCellColor();
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.layer.cornerRadius = 0.0;
    cell.layer.masksToBounds = NO;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.tintColor = UIColor.whiteColor;

    UIView *selected = [UIView new];
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.055];
    cell.selectedBackgroundView = selected;
}

UIImage *WAGRMenuSymbol(NSString *name, __unused UIColor *tint) {
    UIImage *image = name.length ? [UIImage systemImageNamed:name] : nil;
    if (!image) image = [UIImage systemImageNamed:@"circle"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                             weight:UIImageSymbolWeightRegular
                                                              scale:UIImageSymbolScaleMedium];
        image = [image imageByApplyingSymbolConfiguration:configuration] ?: image;
    }
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

BOOL WAGRMenuIsNegativeGateName(NSString *name) {
    NSString *s = name.lowercaseString ?: @"";
    if (!s.length) return NO;
    if ([s containsString:@"kill_switch"] || [s containsString:@"killswitch"] || [s containsString:@"kill-switch"] || [s containsString:@"kill switch"]) return YES;
    if ([s containsString:@"negative"]) return YES;
    if ([s containsString:@"disabled"] || [s containsString:@"disable_"] || [s hasPrefix:@"disable"] || [s containsString:@"_disable"]) return YES;
    if ([s containsString:@"blocked"] || [s containsString:@"block_"] || [s hasPrefix:@"block"] || [s containsString:@"deny"] || [s containsString:@"denied"]) return YES;
    return NO;
}
