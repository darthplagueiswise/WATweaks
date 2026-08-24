#import "WAGRMenuTheme.h"
#import <objc/runtime.h>

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#define WAGR_HAS_UIKIT_GLASS 1
#else
#define WAGR_HAS_UIKIT_GLASS 0
#endif

static const void *kWAGRMenuGlassViewKey = &kWAGRMenuGlassViewKey;

UIColor *WAGRMenuBackgroundColor(void) {
    // WATweaks deliberately uses a true-black canvas. System grouped colors are
    // dark gray and made the runtime browser look washed out on OLED devices.
    return UIColor.blackColor;
}

UIColor *WAGRMenuCellColor(void) {
    return [UIColor colorWithWhite:0.105 alpha:1.0];
}

UIColor *WAGRMenuSecondaryCellColor(void) {
    return [UIColor colorWithWhite:0.14 alpha:1.0];
}

UIColor *WAGRMenuTextColor(void) {
    return UIColor.whiteColor;
}

UIColor *WAGRMenuSecondaryTextColor(void) {
    return [UIColor colorWithWhite:0.68 alpha:1.0];
}

UIColor *WAGRMenuSeparatorColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.12];
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
    return [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
}

UIFont *WAGRMenuRuntimeDetailFont(void) {
    return [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
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

static void WAGRMenuInstallGlassBackground(UIView *host, CGFloat cornerRadius) {
    if (!host) return;
#if WAGR_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        UIVisualEffectView *glass = objc_getAssociatedObject(host, kWAGRMenuGlassViewKey);
        if (!glass) {
            UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            effect.interactive = YES;
            effect.tintColor = [UIColor colorWithWhite:0.08 alpha:0.18];
            glass = [[UIVisualEffectView alloc] initWithEffect:effect];
            glass.userInteractionEnabled = NO;
            glass.clipsToBounds = YES;
            [host insertSubview:glass atIndex:0];
            objc_setAssociatedObject(host, kWAGRMenuGlassViewKey, glass,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        glass.frame = host.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = cornerRadius;
        host.layer.cornerRadius = cornerRadius;
        host.clipsToBounds = YES;
    }
#else
    (void)cornerRadius;
#endif
}

void WAGRMenuApplySearchGlass(UISearchBar *searchBar) {
    if (!searchBar) return;
    searchBar.barStyle = UIBarStyleBlack;
    searchBar.tintColor = UIColor.whiteColor;
    searchBar.barTintColor = UIColor.clearColor;
    searchBar.backgroundColor = UIColor.clearColor;
    searchBar.backgroundImage = [UIImage new];

    if (@available(iOS 13.0, *)) {
        UITextField *field = searchBar.searchTextField;
        field.backgroundColor = UIColor.clearColor;
        field.textColor = UIColor.whiteColor;
        field.tintColor = UIColor.whiteColor;
        field.borderStyle = UITextBorderStyleNone;
        field.leftView.tintColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        WAGRMenuInstallGlassBackground(field, MAX(18.0, CGRectGetHeight(field.bounds) * 0.5));
    }

    UISegmentedControl *scope = (UISegmentedControl *)WAGRMenuFindSubviewOfClass(searchBar, UISegmentedControl.class);
    if (scope) {
        scope.backgroundColor = UIColor.clearColor;
        scope.selectedSegmentTintColor = [UIColor colorWithWhite:0.17 alpha:0.72];
        [scope setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                             forState:UIControlStateNormal];
        [scope setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                             forState:UIControlStateSelected];
        WAGRMenuInstallGlassBackground(scope, MAX(16.0, CGRectGetHeight(scope.bounds) * 0.5));
    }
}

void WAGRMenuApplyTableStyle(UITableView *tableView, UIViewController *owner) {
    if (tableView) {
        tableView.backgroundView = nil;
        tableView.backgroundColor = UIColor.blackColor;
        tableView.separatorColor = WAGRMenuSeparatorColor();
        tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 8.0;
    }

    if (owner) {
        if (@available(iOS 13.0, *)) owner.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        owner.view.backgroundColor = UIColor.blackColor;
        UINavigationBar *bar = owner.navigationController.navigationBar;
        bar.tintColor = UIColor.whiteColor;
        bar.translucent = YES;

        if (@available(iOS 26.0, *)) {
            // Keep UINavigationBar/UIBarButtonItem native so UIKit supplies its
            // own system Liquid Glass. Explicit UIGlassEffect is added only to
            // search/scope chrome via WAGRMenuApplySearchGlass().
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

    // Content stays readable and stable: Liquid Glass is chrome, not one bright
    // visual-effect capsule per scrolling row.
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
