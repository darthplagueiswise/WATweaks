#import "WAGRMenuTheme.h"
#import <objc/runtime.h>

static const void *kWAGRMenuOwnerGlassKey = &kWAGRMenuOwnerGlassKey;
static const void *kWAGRMenuCellGlassKey = &kWAGRMenuCellGlassKey;

static UIColor *WAGRDynamic(UIColor *light, UIColor *dark) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
            return trait.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return dark;
}

UIColor *WAGRMenuBackgroundColor(void) {
    // Real Liquid Glass is not a fake blur/material. On iOS 26+ the glass
    // surface is installed with UIGlassEffect/UIGlassContainerEffect below.
    // This color is only the base behind that live glass and the fallback for
    // iOS versions where the Liquid Glass classes do not exist.
    return WAGRDynamic([UIColor colorWithWhite:0.965 alpha:1.0],
                       [UIColor colorWithWhite:0.025 alpha:1.0]);
}

UIColor *WAGRMenuCellColor(void) {
    return WAGRDynamic([UIColor colorWithWhite:1.0 alpha:0.50],
                       [UIColor colorWithWhite:1.0 alpha:0.085]);
}

UIColor *WAGRMenuSecondaryCellColor(void) { return WAGRMenuCellColor(); }
UIColor *WAGRMenuTextColor(void) { return UIColor.labelColor ?: UIColor.whiteColor; }
UIColor *WAGRMenuSecondaryTextColor(void) { return UIColor.secondaryLabelColor ?: [UIColor colorWithWhite:0.74 alpha:1.0]; }
UIColor *WAGRMenuSeparatorColor(void) { return WAGRDynamic([UIColor colorWithWhite:0.78 alpha:0.32], [UIColor colorWithWhite:1.0 alpha:0.12]); }

static UIVisualEffect *WAGRMenuNewEffectNamed(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    id effect = nil;
    @try { effect = [[cls alloc] init]; } @catch (__unused NSException *ex) { effect = nil; }
    return [effect isKindOfClass:UIVisualEffect.class] ? (UIVisualEffect *)effect : nil;
}

static UIVisualEffect *WAGRMenuNewGlassEffect(void) {
    return WAGRMenuNewEffectNamed(@"UIGlassEffect");
}

static UIVisualEffect *WAGRMenuNewGlassContainerEffect(CGFloat spacing) {
    UIVisualEffect *effect = WAGRMenuNewEffectNamed(@"UIGlassContainerEffect");
    if (!effect) return nil;
    @try { [effect setValue:@(spacing) forKey:@"spacing"]; } @catch (__unused NSException *ex) {}
    return effect;
}

static BOOL WAGRMenuGlassRuntimeAvailable(void) {
    return NSClassFromString(@"UIGlassEffect") != Nil;
}

static NSArray<UIColor *> *WAGRMenuPalette(void) {
    static NSArray<UIColor *> *colors = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[ UIColor.systemCyanColor,
                    UIColor.systemMintColor,
                    UIColor.systemPurpleColor,
                    UIColor.systemOrangeColor,
                    UIColor.systemPinkColor,
                    UIColor.systemBlueColor,
                    UIColor.systemGreenColor,
                    UIColor.systemYellowColor,
                    UIColor.systemTealColor,
                    UIColor.systemIndigoColor,
                    UIColor.systemRedColor ];
    });
    return colors;
}

UIColor *WAGRMenuAccentForIndex(NSInteger index) {
    NSArray<UIColor *> *colors = WAGRMenuPalette();
    if (!colors.count) return UIColor.systemBlueColor;
    return colors[(NSUInteger)(labs((long)index) % (NSInteger)colors.count)];
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

UIFont *WAGRMenuTitleFont(void) { return [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]; }
UIFont *WAGRMenuDetailFont(void) { return [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular]; }
UIFont *WAGRMenuRuntimeTitleFont(void) { return [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightMedium]; }
UIFont *WAGRMenuRuntimeDetailFont(void) { return [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular]; }

static void WAGRMenuConfigureContinuousCorners(UIView *view, CGFloat radius) {
    if (!view) return;
    view.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
}

static void WAGRInstallLiquidGlassBackdrop(UIViewController *owner) {
    if (!owner || !owner.view) return;
    if (objc_getAssociatedObject(owner.view, kWAGRMenuOwnerGlassKey)) return;

    UIVisualEffect *effect = WAGRMenuNewGlassContainerEffect(18.0) ?: WAGRMenuNewGlassEffect();
    if (!effect) return;

    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.frame = owner.view.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.userInteractionEnabled = NO;
    glass.backgroundColor = UIColor.clearColor;
    [owner.view insertSubview:glass atIndex:0];
    objc_setAssociatedObject(owner.view, kWAGRMenuOwnerGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WAGRApplyNavigationLiquidGlassPolicy(UINavigationController *nav) {
    if (!nav) return;
    nav.navigationBar.tintColor = WAGRMenuTextColor();
    nav.toolbar.tintColor = WAGRMenuTextColor();

    // On iOS 26+, UIKit owns the native Liquid Glass chrome. Do not override it
    // with legacy background effects. Older iOS gets transparent chrome over the
    // fallback background.
    if (@available(iOS 26.0, *)) return;

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *bar = [UINavigationBarAppearance new];
        [bar configureWithTransparentBackground];
        bar.backgroundColor = UIColor.clearColor;
        bar.shadowColor = UIColor.clearColor;
        bar.titleTextAttributes = @{ NSForegroundColorAttributeName: WAGRMenuTextColor() };
        nav.navigationBar.standardAppearance = bar;
        nav.navigationBar.scrollEdgeAppearance = bar;
        nav.navigationBar.compactAppearance = bar;

        UIToolbarAppearance *tool = [UIToolbarAppearance new];
        [tool configureWithTransparentBackground];
        tool.backgroundColor = UIColor.clearColor;
        tool.shadowColor = UIColor.clearColor;
        nav.toolbar.standardAppearance = tool;
        if (@available(iOS 15.0, *)) nav.toolbar.scrollEdgeAppearance = tool;
    }
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (owner) {
        owner.view.backgroundColor = WAGRMenuBackgroundColor();
        WAGRInstallLiquidGlassBackdrop(owner);
        WAGRApplyNavigationLiquidGlassPolicy(owner.navigationController);
    }

    if (tableView) {
        tableView.backgroundColor = UIColor.clearColor;
        tableView.separatorColor = WAGRMenuSeparatorColor();
        tableView.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 10.0;
    }
}

static void WAGRMenuInstallCellGlass(UITableViewCell *cell) {
    if (!cell) return;
    if (!WAGRMenuGlassRuntimeAvailable()) {
        cell.backgroundColor = WAGRMenuCellColor();
        return;
    }

    UIVisualEffectView *glass = objc_getAssociatedObject(cell, kWAGRMenuCellGlassKey);
    if (!glass) {
        UIVisualEffect *effect = WAGRMenuNewGlassEffect();
        if (!effect) {
            cell.backgroundColor = WAGRMenuCellColor();
            return;
        }
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.backgroundColor = UIColor.clearColor;
        WAGRMenuConfigureContinuousCorners(glass, 16.0);
        objc_setAssociatedObject(cell, kWAGRMenuCellGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.backgroundView = glass;
    cell.backgroundColor = UIColor.clearColor;
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    if (!cell) return;
    WAGRMenuInstallCellGlass(cell);
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    WAGRMenuConfigureContinuousCorners(cell, 16.0);

    UIView *selected = [UIView new];
    selected.backgroundColor = [WAGRMenuAccentForKey(key, index) colorWithAlphaComponent:0.18];
    WAGRMenuConfigureContinuousCorners(selected, 16.0);
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
