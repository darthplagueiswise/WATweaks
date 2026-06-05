#import "WAGRMenuTheme.h"

static UIColor *WAGRDynamic(UIColor *light, UIColor *dark) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
            return trait.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return dark;
}

UIColor *WAGRMenuBackgroundColor(void) {
    return UIColor.clearColor;
}

UIColor *WAGRMenuCellColor(void) {
    return WAGRDynamic(UIColor.secondarySystemGroupedBackgroundColor,
                       [UIColor colorWithWhite:1.0 alpha:0.060]);
}

UIColor *WAGRMenuSecondaryCellColor(void) { return WAGRMenuCellColor(); }
UIColor *WAGRMenuTextColor(void) { return UIColor.labelColor ?: UIColor.whiteColor; }
UIColor *WAGRMenuSecondaryTextColor(void) { return UIColor.secondaryLabelColor ?: [UIColor colorWithWhite:0.72 alpha:1.0]; }
UIColor *WAGRMenuSeparatorColor(void) { return UIColor.separatorColor ?: [UIColor colorWithWhite:1.0 alpha:0.12]; }

UIColor *WAGRMenuAccentForIndex(NSInteger index) { (void)index; return UIColor.labelColor ?: UIColor.whiteColor; }
UIColor *WAGRMenuAccentForKey(NSString *key, NSInteger fallbackIndex) { (void)key; (void)fallbackIndex; return UIColor.labelColor ?: UIColor.whiteColor; }

UIFont *WAGRMenuTitleFont(void) { return [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold]; }
UIFont *WAGRMenuDetailFont(void) { return [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular]; }
UIFont *WAGRMenuRuntimeTitleFont(void) { return [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightMedium]; }
UIFont *WAGRMenuRuntimeDetailFont(void) { return [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular]; }

static void WAGRApplyNavigationPolicy(UINavigationController *nav) {
    if (!nav) return;
    nav.navigationBar.tintColor = WAGRMenuTextColor();
    nav.toolbar.tintColor = WAGRMenuTextColor();

    if (@available(iOS 26.0, *)) return;

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *bar = [UINavigationBarAppearance new];
        [bar configureWithDefaultBackground];
        bar.titleTextAttributes = @{ NSForegroundColorAttributeName: WAGRMenuTextColor() };
        nav.navigationBar.standardAppearance = bar;
        nav.navigationBar.scrollEdgeAppearance = bar;
        nav.navigationBar.compactAppearance = bar;

        UIToolbarAppearance *tool = [UIToolbarAppearance new];
        [tool configureWithDefaultBackground];
        nav.toolbar.standardAppearance = tool;
        if (@available(iOS 15.0, *)) nav.toolbar.scrollEdgeAppearance = tool;
    }
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (owner) {
        owner.view.backgroundColor = UIColor.systemGroupedBackgroundColor ?: UIColor.blackColor;
        WAGRApplyNavigationPolicy(owner.navigationController);
    }

    if (tableView) {
        tableView.backgroundColor = UIColor.clearColor;
        tableView.separatorColor = WAGRMenuSeparatorColor();
        tableView.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 12.0;
        if (@available(iOS 13.0, *)) tableView.insetsContentViewsToSafeArea = YES;
    }
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    (void)index; (void)key;
    if (!cell) return;
    cell.backgroundColor = WAGRMenuCellColor();
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.detailTextLabel.numberOfLines = 0;

    UIView *selected = [UIView new];
    selected.backgroundColor = WAGRDynamic([UIColor colorWithWhite:0.0 alpha:0.08],
                                           [UIColor colorWithWhite:1.0 alpha:0.10]);
    cell.selectedBackgroundView = selected;
    cell.imageView.tintColor = UIColor.secondaryLabelColor ?: WAGRMenuSecondaryTextColor();
}

UIImage *WAGRMenuSymbol(NSString *name, UIColor *tint) {
    UIImage *img = name.length ? [UIImage systemImageNamed:name] : nil;
    if (!img) img = [UIImage systemImageNamed:@"circle"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular scale:UIImageSymbolScaleMedium];
        img = [img imageByApplyingSymbolConfiguration:cfg] ?: img;
    }
    img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    (void)tint;
    return img;
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
