#import "WAGRMenuTheme.h"

UIColor *WAGRMenuBackgroundColor(void) {
    return [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1.0];
}

UIColor *WAGRMenuCellColor(void) {
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.065 alpha:0.92];
}

UIColor *WAGRMenuSecondaryCellColor(void) {
    return [UIColor colorWithRed:0.075 green:0.075 blue:0.09 alpha:0.88];
}

UIColor *WAGRMenuTextColor(void) {
    return UIColor.whiteColor;
}

UIColor *WAGRMenuSecondaryTextColor(void) {
    return [UIColor colorWithWhite:0.72 alpha:1.0];
}

UIColor *WAGRMenuSeparatorColor(void) {
    return [UIColor colorWithWhite:0.18 alpha:1.0];
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
    if ([s containsString:@"tab"] || [s containsString:@"me_tab"] || [s containsString:@"profile"]) return UIColor.systemPinkColor;
    if ([s containsString:@"debug"] || [s containsString:@"developer"] || [s containsString:@"internal"]) return UIColor.systemBlueColor;
    if ([s containsString:@"kill"] || [s containsString:@"negative"] || [s containsString:@"disable"] || [s containsString:@"block"]) return UIColor.systemRedColor;
    return WAGRMenuAccentForIndex(fallbackIndex);
}

UIFont *WAGRMenuTitleFont(void) {
    return [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
}

UIFont *WAGRMenuDetailFont(void) {
    return [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
}

UIFont *WAGRMenuRuntimeTitleFont(void) {
    return [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
}

UIFont *WAGRMenuRuntimeDetailFont(void) {
    return [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (tableView) {
        tableView.backgroundColor = WAGRMenuBackgroundColor();
        tableView.separatorColor = WAGRMenuSeparatorColor();
        tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        if (@available(iOS 15.0, *)) {
            tableView.sectionHeaderTopPadding = 10.0;
        }
    }
    if (owner) {
        owner.view.backgroundColor = WAGRMenuBackgroundColor();
        owner.navigationController.navigationBar.tintColor = UIColor.whiteColor;
        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
            [ap configureWithTransparentBackground];
            ap.backgroundColor = [UIColor colorWithWhite:0 alpha:0.70];
            ap.titleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.whiteColor };
            owner.navigationController.navigationBar.standardAppearance = ap;
            owner.navigationController.navigationBar.scrollEdgeAppearance = ap;
            owner.navigationController.navigationBar.compactAppearance = ap;
        }
    }
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    if (!cell) return;
    cell.backgroundColor = (index % 2 == 0) ? WAGRMenuCellColor() : WAGRMenuSecondaryCellColor();
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    UIView *selected = [UIView new];
    selected.backgroundColor = [[WAGRMenuAccentForKey(key, index) colorWithAlphaComponent:0.22] colorWithAlphaComponent:0.22];
    cell.selectedBackgroundView = selected;
    cell.imageView.tintColor = WAGRMenuAccentForKey(key, index);
}

UIImage *WAGRMenuSymbol(NSString *name, UIColor *tint) {
    UIImage *img = name.length ? [UIImage systemImageNamed:name] : nil;
    if (!img) img = [UIImage systemImageNamed:@"sparkles"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold scale:UIImageSymbolScaleMedium];
        img = [img imageByApplyingSymbolConfiguration:cfg] ?: img;
    }
    img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
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
