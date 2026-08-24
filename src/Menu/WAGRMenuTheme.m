#import "WAGRMenuTheme.h"

UIColor *WAGRMenuBackgroundColor(void) {
    return UIColor.blackColor;
}

UIColor *WAGRMenuCellColor(void) {
    return [UIColor colorWithWhite:0.095 alpha:1.0];
}

UIColor *WAGRMenuSecondaryCellColor(void) {
    return [UIColor colorWithWhite:0.125 alpha:1.0];
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

static NSArray<UIColor *> *WAGRMenuPalette(void) {
    static NSArray<UIColor *> *colors = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[
            UIColor.systemCyanColor,
            UIColor.systemMintColor,
            UIColor.systemPurpleColor,
            UIColor.systemOrangeColor,
            UIColor.systemPinkColor,
            UIColor.systemBlueColor,
            UIColor.systemGreenColor,
            UIColor.systemYellowColor,
            UIColor.systemTealColor,
            UIColor.systemIndigoColor,
            UIColor.systemRedColor
        ];
    });
    return colors;
}

UIColor *WAGRMenuAccentForIndex(NSInteger index) {
    NSArray<UIColor *> *colors = WAGRMenuPalette();
    if (!colors.count) return UIColor.systemBlueColor;
    NSInteger i = labs((long)index) % (NSInteger)colors.count;
    return colors[(NSUInteger)i];
}

UIColor *WAGRMenuAccentForKey(NSString *key, NSInteger fallbackIndex) {
    NSString *s = key.lowercaseString ?: @"";
    if ([s containsString:@"liquid"] || [s containsString:@"glass"] || [s containsString:@"wds"]) return UIColor.systemCyanColor;
    if ([s containsString:@"aura"] || [s containsString:@"plus"] || [s containsString:@"subscription"]) return UIColor.systemPurpleColor;
    if ([s containsString:@"username"] || [s containsString:@"identity"]) return UIColor.systemMintColor;
    if ([s containsString:@"online"] || [s containsString:@"contacts"] || [s containsString:@"presence"]) return UIColor.systemGreenColor;
    if ([s containsString:@"about"] || [s containsString:@"evolve"] || [s containsString:@"evolution"]) return UIColor.systemOrangeColor;
    if ([s containsString:@"tab"] || [s containsString:@"profile"]) return UIColor.systemPinkColor;
    if ([s containsString:@"debug"] || [s containsString:@"developer"] || [s containsString:@"internal"]) return UIColor.systemBlueColor;
    if ([s containsString:@"kill"] || [s containsString:@"negative"] || [s containsString:@"disable"] || [s containsString:@"block"]) return UIColor.systemRedColor;
    return WAGRMenuAccentForIndex(fallbackIndex);
}

UIFont *WAGRMenuTitleFont(void) {
    return [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
}

UIFont *WAGRMenuDetailFont(void) {
    return [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
}

UIFont *WAGRMenuRuntimeTitleFont(void) {
    return [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
}

UIFont *WAGRMenuRuntimeDetailFont(void) {
    return [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
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
        // UISearchController/UISearchBar and UISegmentedControl already receive
        // the system Liquid Glass treatment from UIKit. Do NOT insert an extra
        // UIVisualEffectView/UIGlassEffectStyleRegular inside searchTextField:
        // that creates the visible "pill inside a pill" regression.
        UITextField *field = searchBar.searchTextField;
        field.textColor = UIColor.whiteColor;
        field.tintColor = UIColor.whiteColor;
        field.leftView.tintColor = [UIColor colorWithWhite:0.90 alpha:1.0];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;

        UISegmentedControl *scope = (UISegmentedControl *)WAGRMenuFindSubviewOfClass(searchBar, UISegmentedControl.class);
        if (scope) {
            [scope setTitleTextAttributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.82 alpha:1.0],
                NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular]
            } forState:UIControlStateNormal];
            [scope setTitleTextAttributes:@{
                NSForegroundColorAttributeName: UIColor.whiteColor,
                NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium]
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
        tableView.sectionHeaderHeight = 0.0;
        tableView.sectionFooterHeight = 0.0;
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

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    if (!cell) return;
    UIColor *accent = WAGRMenuAccentForKey(key, index);
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
    cell.imageView.tintColor = accent;

    UIView *selected = [UIView new];
    selected.backgroundColor = [accent colorWithAlphaComponent:0.08];
    cell.selectedBackgroundView = selected;
}

UIImage *WAGRMenuSymbol(NSString *name, UIColor *tint) {
    UIImage *image = name.length ? [UIImage systemImageNamed:name] : nil;
    if (!image) image = [UIImage systemImageNamed:@"sparkles"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:16.0
                                                             weight:UIImageSymbolWeightMedium
                                                              scale:UIImageSymbolScaleSmall];
        image = [image imageByApplyingSymbolConfiguration:configuration] ?: image;
    }
    (void)tint;
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
