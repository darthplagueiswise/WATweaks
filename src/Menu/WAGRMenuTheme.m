#import "WAGRMenuTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static NSInteger const kWAGRGlassBackgroundTag = 0x57475226;

BOOL WAGRIsIOS26OrNewer(void) {
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

static UIColor *WAGRDynamic(UIColor *light, UIColor *dark) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
            return trait.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return dark;
}

UIVisualEffect *WAGRRealLiquidGlassEffect(BOOL clearStyle, BOOL interactive, UIColor *tintColor) {
    if (!WAGRIsIOS26OrNewer()) return nil;
    Class cls = NSClassFromString(@"UIGlassEffect");
    if (!cls) return nil;
    id effect = nil;
    SEL withStyle = NSSelectorFromString(@"effectWithStyle:");
    if ([cls respondsToSelector:withStyle]) {
        effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(cls, withStyle, clearStyle ? 0 : 1);
    } else {
        effect = [[cls alloc] init];
    }
    if (interactive) {
        SEL setInteractive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:setInteractive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, YES);
        SEL setIsInteractive = NSSelectorFromString(@"setIsInteractive:");
        if ([effect respondsToSelector:setIsInteractive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setIsInteractive, YES);
    }
    if (tintColor) {
        SEL setTint = NSSelectorFromString(@"setTintColor:");
        if ([effect respondsToSelector:setTint]) ((void (*)(id, SEL, id))objc_msgSend)(effect, setTint, tintColor);
    }
    return [effect isKindOfClass:UIVisualEffect.class] ? (UIVisualEffect *)effect : nil;
}

UIColor *WAGRGlassBaseSurfaceColor(void) {
    return WAGRDynamic([UIColor colorWithWhite:0.985 alpha:1.0], [UIColor colorWithWhite:0.0 alpha:1.0]);
}

UIColor *WAGRGlassReadableFillColor(void) {
    return WAGRDynamic([UIColor colorWithWhite:1.0 alpha:0.72], [UIColor colorWithWhite:1.0 alpha:0.080]);
}

UIColor *WAGRMenuBackgroundColor(void) { return WAGRGlassBaseSurfaceColor(); }
UIColor *WAGRMenuCellColor(void) { return WAGRGlassReadableFillColor(); }
UIColor *WAGRMenuSecondaryCellColor(void) { return WAGRMenuCellColor(); }
UIColor *WAGRMenuTextColor(void) { return UIColor.labelColor ?: UIColor.whiteColor; }
UIColor *WAGRMenuSecondaryTextColor(void) { return UIColor.secondaryLabelColor ?: [UIColor colorWithWhite:0.72 alpha:1.0]; }
UIColor *WAGRMenuSeparatorColor(void) { return UIColor.clearColor; }
UIColor *WAGRMenuAccentForIndex(NSInteger index) { (void)index; return UIColor.labelColor ?: UIColor.whiteColor; }
UIColor *WAGRMenuAccentForKey(NSString *key, NSInteger fallbackIndex) { (void)key; (void)fallbackIndex; return UIColor.labelColor ?: UIColor.whiteColor; }
UIFont *WAGRMenuTitleFont(void) { return [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; }
UIFont *WAGRMenuDetailFont(void) { return [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; }
UIFont *WAGRMenuRuntimeTitleFont(void) { return [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightSemibold]; }
UIFont *WAGRMenuRuntimeDetailFont(void) { return [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular]; }

static void WAGRApplyOfficialContainerGlass(UIViewController *vc) {
    if (!vc || !WAGRIsIOS26OrNewer()) return;
    NSInteger glassStyle = 1;
    SEL preferred = NSSelectorFromString(@"setPreferredContainerBackgroundStyle:");
    SEL direct = NSSelectorFromString(@"setContainerBackgroundStyle:");
    if ([vc respondsToSelector:preferred]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(vc, preferred, glassStyle);
    else if ([vc respondsToSelector:direct]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(vc, direct, glassStyle);
}

static UIVisualEffectView *WAGREnsureGlassBackground(UIView *view, CGFloat radius, BOOL interactive, BOOL clearStyle) {
    if (!view || !WAGRIsIOS26OrNewer()) return nil;
    UIVisualEffect *effect = WAGRRealLiquidGlassEffect(clearStyle, interactive, nil);
    if (!effect) return nil;

    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)view;
        ev.effect = effect;
        ev.backgroundColor = UIColor.clearColor;
        ev.contentView.backgroundColor = UIColor.clearColor;
        ev.layer.cornerRadius = radius;
        if ([ev.layer respondsToSelector:@selector(setCornerCurve:)]) ev.layer.cornerCurve = kCACornerCurveContinuous;
        ev.clipsToBounds = YES;
        ev.layer.masksToBounds = YES;
        return ev;
    }

    UIVisualEffectView *glass = (UIVisualEffectView *)[view viewWithTag:kWAGRGlassBackgroundTag];
    if (![glass isKindOfClass:UIVisualEffectView.class]) {
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.tag = kWAGRGlassBackgroundTag;
        glass.userInteractionEnabled = NO;
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [view insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.topAnchor constraintEqualToAnchor:view.topAnchor],
            [glass.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
    } else {
        glass.effect = effect;
    }
    glass.backgroundColor = UIColor.clearColor;
    glass.contentView.backgroundColor = UIColor.clearColor;
    glass.layer.cornerRadius = radius;
    if ([glass.layer respondsToSelector:@selector(setCornerCurve:)]) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;
    glass.layer.masksToBounds = YES;
    view.backgroundColor = UIColor.clearColor;
    view.layer.cornerRadius = radius;
    if ([view.layer respondsToSelector:@selector(setCornerCurve:)]) view.layer.cornerCurve = kCACornerCurveContinuous;
    return glass;
}

static void WAGRConfigureScrollViewForGlass(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) {
        UITableView *tv = (UITableView *)view;
        tv.backgroundColor = UIColor.clearColor;
        tv.backgroundView = nil;
        tv.separatorStyle = UITableViewCellSeparatorStyleNone;
        tv.separatorColor = UIColor.clearColor;
        if (@available(iOS 15.0, *)) tv.sectionHeaderTopPadding = 0.0;
        if (WAGRIsIOS26OrNewer()) {
            SEL setBackgroundEffect = NSSelectorFromString(@"setBackgroundEffect:");
            if ([tv respondsToSelector:setBackgroundEffect]) ((void (*)(id, SEL, id))objc_msgSend)(tv, setBackgroundEffect, WAGRRealLiquidGlassEffect(YES, NO, nil));
        }
    } else if ([view isKindOfClass:UIScrollView.class]) {
        view.backgroundColor = UIColor.clearColor;
    }
}

void WAGRStyleSearchBarForGlass(UISearchBar *searchBar) {
    if (!searchBar) return;
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.backgroundImage = UIImage.new;
    searchBar.backgroundColor = UIColor.clearColor;
    searchBar.barTintColor = UIColor.clearColor;
    searchBar.translucent = YES;
    UITextField *field = searchBar.searchTextField;
    if (!field) return;
    field.borderStyle = UITextBorderStyleNone;
    field.background = nil;
    field.disabledBackground = nil;
    field.backgroundColor = UIColor.clearColor;
    field.layer.backgroundColor = UIColor.clearColor.CGColor;
    field.layer.cornerRadius = 0.0;
    field.layer.masksToBounds = NO;
    field.clipsToBounds = NO;
    field.textColor = UIColor.labelColor;
    field.tintColor = UIColor.labelColor;
    field.leftView.tintColor = UIColor.secondaryLabelColor;
    field.rightView.tintColor = UIColor.secondaryLabelColor;
    NSString *placeholder = field.attributedPlaceholder.string ?: field.placeholder ?: @"";
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{ NSForegroundColorAttributeName: UIColor.secondaryLabelColor }];
}

void WAGRApplyGlassToButton(UIButton *button, BOOL prominent) {
    if (!button) return;
    button.backgroundColor = UIColor.clearColor;
    if (@available(iOS 15.0, *)) {
        NSString *title = [button titleForState:UIControlStateNormal];
        UIImage *image = [button imageForState:UIControlStateNormal];
        UIButtonConfiguration *cfg = button.configuration;
        if (!cfg) {
            Class cfgCls = UIButtonConfiguration.class;
            SEL glassSel = NSSelectorFromString(prominent ? @"prominentGlassButtonConfiguration" : @"clearGlassButtonConfiguration");
            if (WAGRIsIOS26OrNewer() && [cfgCls respondsToSelector:glassSel]) cfg = ((UIButtonConfiguration *(*)(id, SEL))objc_msgSend)(cfgCls, glassSel);
            else cfg = prominent ? [UIButtonConfiguration tintedButtonConfiguration] : [UIButtonConfiguration plainButtonConfiguration];
        }
        if (title.length) cfg.title = title;
        if (image) cfg.image = image;
        cfg.baseForegroundColor = UIColor.labelColor;
        cfg.background.backgroundColor = UIColor.clearColor;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        button.configuration = cfg;
    } else {
        WAGREnsureGlassBackground(button, 18.0, YES, NO);
    }
}

static BOOL WAGRViewShouldReceiveGlass(UIView *v) {
    if (!v || v.tag == kWAGRGlassBackgroundTag) return NO;
    if ([v isKindOfClass:UILabel.class] || [v isKindOfClass:UIImageView.class] || [v isKindOfClass:UIStackView.class]) return NO;
    if ([v isKindOfClass:UITableView.class] || [v isKindOfClass:UICollectionView.class] || [v isKindOfClass:UIScrollView.class]) return NO;
    if ([v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UITableViewHeaderFooterView.class]) return NO;
    if ([v isKindOfClass:UISearchBar.class] || [v isKindOfClass:UISegmentedControl.class] || [v isKindOfClass:UIButton.class]) return YES;
    return NO;
}

void WAGRApplyLiquidGlassToViewTree(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:root.subviews];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.tag == kWAGRGlassBackgroundTag) continue;
        WAGRConfigureScrollViewForGlass(v);
        if ([v isKindOfClass:UISearchBar.class]) WAGRStyleSearchBarForGlass((UISearchBar *)v);
        else if ([v isKindOfClass:UIButton.class]) WAGRApplyGlassToButton((UIButton *)v, NO);
        else if (WAGRViewShouldReceiveGlass(v)) WAGREnsureGlassBackground(v, v.layer.cornerRadius > 0 ? v.layer.cornerRadius : 16.0, [v isKindOfClass:UIControl.class], NO);
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

void WAGRApplyGlassBackdropToViewController(UIViewController *vc) {
    if (!vc) return;
    if (!vc.isViewLoaded) [vc loadViewIfNeeded];
    WAGRApplyOfficialContainerGlass(vc);
    vc.view.backgroundColor = WAGRGlassBaseSurfaceColor();
    vc.view.opaque = YES;
    vc.view.layer.backgroundColor = [WAGRGlassBaseSurfaceColor() resolvedColorWithTraitCollection:vc.view.traitCollection].CGColor;
    WAGRConfigureScrollViewForGlass(vc.view);
    WAGRApplyLiquidGlassToViewTree(vc.view);

    UINavigationBar *bar = vc.navigationController.navigationBar;
    if (bar) {
        bar.tintColor = UIColor.labelColor;
        bar.translucent = YES;
        bar.backgroundColor = UIColor.clearColor;
        bar.prefersLargeTitles = NO;
        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
            [ap configureWithTransparentBackground];
            ap.backgroundColor = UIColor.clearColor;
            ap.shadowColor = UIColor.clearColor;
            ap.titleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.labelColor };
            bar.standardAppearance = ap;
            bar.scrollEdgeAppearance = ap;
            bar.compactAppearance = ap;
        }
    }
    UIToolbar *tb = vc.navigationController.toolbar;
    if (tb && @available(iOS 13.0, *)) {
        UIToolbarAppearance *ap = [UIToolbarAppearance new];
        [ap configureWithTransparentBackground];
        ap.backgroundColor = UIColor.clearColor;
        ap.shadowColor = UIColor.clearColor;
        tb.standardAppearance = ap;
        if (@available(iOS 15.0, *)) tb.scrollEdgeAppearance = ap;
        tb.translucent = YES;
        tb.backgroundColor = UIColor.clearColor;
    }
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (owner) WAGRApplyGlassBackdropToViewController(owner);
    if (tableView) {
        WAGRConfigureScrollViewForGlass(tableView);
        tableView.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        if (@available(iOS 13.0, *)) tableView.insetsContentViewsToSafeArea = YES;
        tableView.rowHeight = UITableViewAutomaticDimension;
        tableView.estimatedRowHeight = 74.0;
    }
}

void WAGRMenuApplyCellStyle(UITableViewCell *cell, NSInteger index, NSString *key) {
    (void)index; (void)key;
    if (!cell) return;
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 4;
    UIView *selected = [UIView new];
    selected.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
    cell.selectedBackgroundView = selected;
    cell.imageView.tintColor = WAGRMenuSecondaryTextColor();
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *bg = [UIBackgroundConfiguration clearConfiguration];
        bg.backgroundColor = WAGRGlassReadableFillColor();
        bg.visualEffect = WAGRRealLiquidGlassEffect(NO, YES, nil);
        bg.cornerRadius = 18.0;
        bg.strokeWidth = 0.0;
        cell.backgroundConfiguration = bg;
        cell.backgroundView = nil;
    } else {
        WAGREnsureGlassBackground(cell.contentView, 14.0, YES, NO);
    }
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
