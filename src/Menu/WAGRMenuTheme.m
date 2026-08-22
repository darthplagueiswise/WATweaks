#import "WAGRMenuTheme.h"
#import <QuartzCore/QuartzCore.h>

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000
#import <UIKit/UIGlassEffect.h>
#endif

static UIVisualEffect *WAGRMenuGlassEffect(BOOL clearStyle, UIColor *tint, BOOL interactive) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *effect = [UIGlassEffect effectWithStyle:
            clearStyle ? UIGlassEffectStyleClear : UIGlassEffectStyleRegular];
        effect.interactive = interactive;
        effect.tintColor = tint;
        return effect;
    }
#endif
    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:clearStyle
            ? UIBlurEffectStyleSystemThinMaterialDark
            : UIBlurEffectStyleSystemMaterialDark];
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

static UIVisualEffectView *WAGRMenuGlassView(BOOL clearStyle,
                                             UIColor *tint,
                                             BOOL interactive,
                                             CGFloat cornerRadius) {
    UIVisualEffectView *view = [[UIVisualEffectView alloc]
        initWithEffect:WAGRMenuGlassEffect(clearStyle, tint, interactive)];
    view.userInteractionEnabled = NO;
    view.backgroundColor = UIColor.clearColor;
    view.layer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *)) view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
    return view;
}

UIColor *WAGRMenuBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.systemBackgroundColor;
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
    return [UIColor colorWithWhite:0.74 alpha:1.0];
}

UIColor *WAGRMenuSeparatorColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.separatorColor;
    return [UIColor colorWithWhite:0.25 alpha:1.0];
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

static void WAGRMenuInstallTableGlass(UITableView *tableView) {
    if (!tableView) return;
    UIColor *tint = [UIColor.systemBlueColor colorWithAlphaComponent:0.035];
    UIVisualEffectView *background = WAGRMenuGlassView(NO, tint, NO, 0.0);
    background.frame = tableView.bounds;
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableView.backgroundView = background;
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (tableView) {
        tableView.backgroundColor = UIColor.clearColor;
        tableView.separatorColor = [WAGRMenuSeparatorColor() colorWithAlphaComponent:0.34];
        tableView.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 8.0;
        WAGRMenuInstallTableGlass(tableView);
    }

    if (owner) {
        owner.view.backgroundColor = WAGRMenuBackgroundColor();
        UINavigationBar *bar = owner.navigationController.navigationBar;
        bar.tintColor = WAGRMenuTextColor();
        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
            [appearance configureWithTransparentBackground];
            appearance.backgroundColor = UIColor.clearColor;
            appearance.shadowColor = UIColor.clearColor;
            appearance.titleTextAttributes = @{
                NSForegroundColorAttributeName: WAGRMenuTextColor(),
                NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]
            };
            appearance.backgroundEffect = WAGRMenuGlassEffect(NO,
                [UIColor.systemBlueColor colorWithAlphaComponent:0.025], NO);
            bar.standardAppearance = appearance;
            bar.scrollEdgeAppearance = appearance;
            bar.compactAppearance = appearance;
        }
    }
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    if (!cell) return;
    UIColor *accent = WAGRMenuAccentForKey(key, index);

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.tintColor = accent;

    // iOS 26: real public UIGlassEffect. Earlier systems receive the closest
    // system material fallback. backgroundView avoids stacking subviews when
    // UITableView reuses cells.
    cell.backgroundView = WAGRMenuGlassView(YES,
        [accent colorWithAlphaComponent:0.055], YES, 16.0);
    cell.selectedBackgroundView = WAGRMenuGlassView(NO,
        [accent colorWithAlphaComponent:0.20], YES, 16.0);

    cell.layer.cornerRadius = 16.0;
    if (@available(iOS 13.0, *)) cell.layer.cornerCurve = kCACornerCurveContinuous;
    cell.layer.masksToBounds = YES;
}

UIImage *WAGRMenuSymbol(NSString *name, UIColor *tint) {
    UIImage *image = name.length ? [UIImage systemImageNamed:name] : nil;
    if (!image) image = [UIImage systemImageNamed:@"sparkles"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                             weight:UIImageSymbolWeightSemibold
                                                              scale:UIImageSymbolScaleMedium];
        image = [image imageByApplyingSymbolConfiguration:configuration] ?: image;
    }
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    (void)tint;
    return image;
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
