#import "WAGRMenuTheme.h"

UIColor *WAGRMenuBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.systemGroupedBackgroundColor;
    return UIColor.blackColor;
}

UIColor *WAGRMenuCellColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondarySystemGroupedBackgroundColor;
    return [UIColor colorWithWhite:0.11 alpha:1.0];
}

UIColor *WAGRMenuSecondaryCellColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.tertiarySystemGroupedBackgroundColor;
    return WAGRMenuCellColor();
}

UIColor *WAGRMenuTextColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.labelColor;
    return UIColor.whiteColor;
}

UIColor *WAGRMenuSecondaryTextColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondaryLabelColor;
    return [UIColor colorWithWhite:0.72 alpha:1.0];
}

UIColor *WAGRMenuSeparatorColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.separatorColor;
    return [UIColor colorWithWhite:0.22 alpha:1.0];
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
    return [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
}

UIFont *WAGRMenuDetailFont(void) {
    return [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
}

UIFont *WAGRMenuRuntimeTitleFont(void) {
    return [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
}

UIFont *WAGRMenuRuntimeDetailFont(void) {
    return [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (tableView) {
        // Inset-grouped tables already provide the correct grouped geometry and
        // corner treatment. Do not put a UIVisualEffectView behind every row or
        // behind the entire table: that creates the washed-out "glass card"
        // appearance seen in the previous build.
        tableView.backgroundView = nil;
        tableView.backgroundColor = WAGRMenuBackgroundColor();
        tableView.separatorColor = WAGRMenuSeparatorColor();
        tableView.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 8.0;
    }

    if (owner) {
        owner.view.backgroundColor = WAGRMenuBackgroundColor();
        UINavigationBar *bar = owner.navigationController.navigationBar;
        bar.tintColor = WAGRMenuTextColor();
        bar.translucent = YES;

        if (@available(iOS 26.0, *)) {
            // On iOS 26 UIKit's own UINavigationBar / UIBarButtonItem / search
            // chrome adopts Liquid Glass automatically. Leaving the appearance
            // native is the correct implementation; forcing UIGlassEffect as a
            // backgroundEffect double-renders the material and destroys contrast.
        } else if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
            [appearance configureWithDefaultBackground];
            appearance.backgroundColor = UIColor.systemGroupedBackgroundColor;
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName: WAGRMenuTextColor()};
            bar.standardAppearance = appearance;
            bar.scrollEdgeAppearance = appearance;
            bar.compactAppearance = appearance;
        }
    }
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    if (!cell) return;
    UIColor *accent = WAGRMenuAccentForKey(key, index);

    // Let UITableViewStyleInsetGrouped own the card/group shape. The cell itself
    // is a normal system grouped row; Liquid Glass belongs to navigation/search/
    // action chrome, not to every scrolling content row.
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
    selected.backgroundColor = [accent colorWithAlphaComponent:0.10];
    cell.selectedBackgroundView = selected;
}

UIImage *WAGRMenuSymbol(NSString *name, UIColor *tint) {
    UIImage *image = name.length ? [UIImage systemImageNamed:name] : nil;
    if (!image) image = [UIImage systemImageNamed:@"sparkles"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                             weight:UIImageSymbolWeightMedium
                                                              scale:UIImageSymbolScaleMedium];
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
