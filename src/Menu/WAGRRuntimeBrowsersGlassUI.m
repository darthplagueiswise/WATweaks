#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

static const void *kWAGRGlassTitleLabelKey = &kWAGRGlassTitleLabelKey;
static const void *kWAGRGlassTitleEffectKey = &kWAGRGlassTitleEffectKey;
static const void *kWAGRBottomSearchItemKey = &kWAGRBottomSearchItemKey;

static NSMutableDictionary<NSString *, NSValue *> *gWAGRDidLoadOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRDidLayoutOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRWillAppearOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRWillDisappearOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRCellOriginals;

static IMP WAGRBrowserOriginalIMP(id object,
                                  SEL selector,
                                  NSDictionary<NSString *, NSValue *> *map) {
    Class cls = [object class];
    while (cls) {
        NSString *key = [NSString stringWithFormat:@"%@|%@",
                         NSStringFromClass(cls) ?: @"?",
                         NSStringFromSelector(selector) ?: @"?"];
        NSValue *value = map[key];
        if (value) return (IMP)value.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static BOOL WAGRBrowserInstallMethod(Class cls,
                                     SEL selector,
                                     IMP replacement,
                                     NSMutableDictionary<NSString *, NSValue *> *map) {
    if (!cls || !selector || !replacement || !map) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    if (original == replacement) return YES;

    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     NSStringFromClass(cls) ?: @"?",
                     NSStringFromSelector(selector) ?: @"?"];
    map[key] = [NSValue valueWithPointer:original];

    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) return YES;
    method_setImplementation(method, replacement);
    return YES;
}

#pragma mark - Liquid Glass title bubble

static void WAGRBrowserUpdateGlassTitle(UIViewController *controller) {
    if (!controller) return;
    NSString *title = controller.title.length ? controller.title : @"WATweaks";
    UILabel *label = objc_getAssociatedObject(controller, kWAGRGlassTitleLabelKey);
    UIView *effectView = objc_getAssociatedObject(controller, kWAGRGlassTitleEffectKey);
    UIView *container = controller.navigationItem.titleView;

    if (!label || !effectView || !container) {
        container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 130, 38)];
        container.backgroundColor = UIColor.clearColor;
        container.layer.cornerCurve = kCACornerCurveContinuous;
        container.layer.cornerRadius = 19.0;
        container.clipsToBounds = YES;

        UIVisualEffect *effect = nil;
        if (@available(iOS 26.0, *)) {
            UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            glass.interactive = NO;
            effect = glass;
        } else {
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        }
        UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
        glassView.userInteractionEnabled = NO;
        glassView.frame = container.bounds;
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:glassView];

        label = [[UILabel alloc] initWithFrame:container.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.72;
        label.numberOfLines = 1;
        [container addSubview:label];

        objc_setAssociatedObject(controller, kWAGRGlassTitleLabelKey, label,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kWAGRGlassTitleEffectKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        controller.navigationItem.titleView = container;
    }

    label.text = title;
    CGFloat measured = ceil([title sizeWithAttributes:@{NSFontAttributeName: label.font}].width) + 34.0;
    CGFloat width = MIN(238.0, MAX(104.0, measured));
    container.frame = CGRectMake(0, 0, width, 38.0);
    effectView.frame = container.bounds;
    label.frame = CGRectInset(container.bounds, 12.0, 0.0);
}

#pragma mark - Native iOS 26 morphing search in the bottom-left toolbar

static UISearchController *WAGRBrowserSearchController(id controller) {
    for (NSString *key in @[@"searchController", @"search"]) {
        @try {
            id candidate = [controller valueForKey:key];
            if ([candidate isKindOfClass:UISearchController.class]) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void WAGRBrowserConfigureSearch(UIViewController *controller) {
    UISearchController *search = WAGRBrowserSearchController(controller);
    if (!search) return;

    search.obscuresBackgroundDuringPresentation = NO;
    search.hidesNavigationBarDuringPresentation = NO;
    WAGRMenuApplySearchGlass(search.searchBar);

    if (@available(iOS 26.0, *)) {
        UINavigationItem *item = controller.navigationItem;
        item.searchController = search;
        item.hidesSearchBarWhenScrolling = YES;

        SEL allowToolbar = NSSelectorFromString(@"setSearchBarPlacementAllowsToolbarIntegration:");
        if ([item respondsToSelector:allowToolbar]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, allowToolbar, YES);
        }

        SEL placementItemSelector = NSSelectorFromString(@"searchBarPlacementBarButtonItem");
        UIBarButtonItem *searchPlacement = nil;
        if ([item respondsToSelector:placementItemSelector]) {
            searchPlacement = ((id (*)(id, SEL))objc_msgSend)(item, placementItemSelector);
        }
        if (searchPlacement) {
            UIBarButtonItem *stored = objc_getAssociatedObject(controller, kWAGRBottomSearchItemKey);
            if (stored != searchPlacement || controller.toolbarItems.count != 2) {
                UIBarButtonItem *flex = [[UIBarButtonItem alloc]
                    initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                    target:nil action:nil];
                // Search placement first = bottom-left. On iOS 26 UIKit owns the
                // morphing Liquid Glass transition from compact button to field.
                controller.toolbarItems = @[ searchPlacement, flex ];
                objc_setAssociatedObject(controller, kWAGRBottomSearchItemKey, searchPlacement,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static BOOL WAGRBrowserUsesBottomSearch(UIViewController *controller) {
    if (@available(iOS 26.0, *)) return WAGRBrowserSearchController(controller) != nil;
    return NO;
}

#pragma mark - Compact single-line browser cells

static NSString *WAGRBrowserFirstDetailLine(NSString *detail) {
    if (!detail.length) return @"";
    return [detail componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject ?: @"";
}

static NSString *WAGRBrowserStripStateSuffix(NSString *value) {
    NSString *result = value ?: @"";
    for (NSString *suffix in @[ @" · INSTALLED", @" · PENDING", @" · ORIGINAL" ]) {
        if ([result hasSuffix:suffix]) {
            result = [result substringToIndex:result.length - suffix.length];
            break;
        }
    }
    return result;
}

static NSString *WAGRBrowserCompactValue(NSString *value) {
    if (!value.length) return @"?";
    NSString *flat = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (flat.length > 70) flat = [[flat substringToIndex:70] stringByAppendingString:@"…"];
    return flat;
}

static BOOL WAGRBrowserValueUnavailable(NSString *value) {
    if (!value.length) return YES;
    NSString *lower = value.lowercaseString;
    return [lower containsString:@"indisponível"] || [lower containsString:@"exception"];
}

static void WAGRBrowserApplyCompactLabels(UITableViewCell *cell) {
    if (!cell) return;
    // Runtime identities are long. Keep every selector on one physical line and
    // scale only that line, rather than wrapping and doubling row height.
    cell.textLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.42;
    cell.textLabel.lineBreakMode = NSLineBreakByClipping;

    cell.detailTextLabel.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.58;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByClipping;
}

static WAGRABPropEntry *WAGRBrowserABEntry(id controller, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (![controller respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, indexPath);
}

static NSString *WAGRBrowserNativeStableID(id controller, WAGRABPropEntry *entry) {
    NSString *stableID = WAGRABPropsStableIDForTarget(entry.className,
                                                       entry.selectorName,
                                                       entry.classMethod);
    if (stableID.length) return stableID;

    SEL selector = NSSelectorFromString(@"nativeEntryForRuntimeEntry:");
    if (![controller respondsToSelector:selector]) return nil;
    NSDictionary *native = ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, entry);
    id code = [native isKindOfClass:NSDictionary.class] ? native[@"code"] : nil;
    if ([code isKindOfClass:NSString.class]) return code;
    if ([code respondsToSelector:@selector(stringValue)]) return [code stringValue];
    return nil;
}

static NSString *WAGRBrowserOriginalText(NSString *className,
                                         NSString *selectorName,
                                         BOOL meta) {
    id raw = nil;
    NSString *value = WAGRRuntimeValueReadOriginal(className, selectorName, meta, nil, &raw);
    return WAGRBrowserValueUnavailable(value) ? nil : WAGRBrowserCompactValue(value);
}

static void WAGRBrowserPostProcessABCell(id controller,
                                         UITableViewCell *cell,
                                         NSIndexPath *indexPath) {
    WAGRABPropEntry *entry = WAGRBrowserABEntry(controller, indexPath);
    if (!entry || !cell) return;
    WAGRBrowserApplyCompactLabels(cell);

    cell.textLabel.text = entry.selectorName ?: @"?";
    NSString *stableID = WAGRBrowserNativeStableID(controller, entry);
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className,
                                                   entry.selectorName,
                                                   entry.classMethod);
    BOOL installed = overridden && WAGRRuntimeValueHookIsInstalled(entry.className,
                                                                    entry.selectorName,
                                                                    entry.classMethod);
    NSString *existing = WAGRBrowserFirstDetailLine(cell.detailTextLabel.text);
    if ([existing hasPrefix:@"Atual: "]) existing = [existing substringFromIndex:7];
    existing = WAGRBrowserCompactValue(WAGRBrowserStripStateSuffix(existing));
    NSString *idText = stableID.length ? [NSString stringWithFormat:@"AB %@", stableID] : @"AB —";
    NSString *state = overridden ? (installed ? @"override" : @"pending") : @"original";

    if (overridden) {
        NSString *original = WAGRBrowserOriginalText(entry.className, entry.selectorName, entry.classMethod);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · orig %@ → eff %@ · %@",
                                     idText,
                                     entry.typeName.length ? entry.typeName : entry.typeCode,
                                     original.length ? original : @"aguardando receiver",
                                     existing.length ? existing : @"?",
                                     state];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · original",
                                     idText,
                                     entry.typeName.length ? entry.typeName : entry.typeCode,
                                     existing.length ? existing : @"aguardando receiver"];
    }
    cell.detailTextLabel.textColor = overridden
        ? (installed ? UIColor.systemCyanColor : UIColor.systemOrangeColor)
        : WAGRMenuSecondaryTextColor();
}

static WAGREntry *WAGRBrowserSurfaceEntry(id controller, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (![controller respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, indexPath);
}

static void WAGRBrowserPostProcessSurfaceCell(id controller,
                                              UITableViewCell *cell,
                                              NSIndexPath *indexPath) {
    WAGREntry *entry = WAGRBrowserSurfaceEntry(controller, indexPath);
    if (!entry || !cell) return;
    WAGRBrowserApplyCompactLabels(cell);

    cell.textLabel.text = entry.selectorName ?: entry.displayName ?: @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className,
                                                   entry.selectorName,
                                                   entry.isClassMethod);
    BOOL installed = overridden && WAGRRuntimeValueHookIsInstalled(entry.className,
                                                                    entry.selectorName,
                                                                    entry.isClassMethod);
    NSString *detail = cell.detailTextLabel.text ?: @"";
    NSString *current = @"";
    for (NSString *line in [detail componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if ([line hasPrefix:@"Atual: "]) { current = [line substringFromIndex:7]; break; }
    }
    current = WAGRBrowserCompactValue(WAGRBrowserStripStateSuffix(current));
    NSString *state = overridden ? (installed ? @"override" : @"pending") : @"original";

    if (overridden) {
        NSString *original = WAGRBrowserOriginalText(entry.className, entry.selectorName, entry.isClassMethod);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · orig %@ → eff %@ · %@",
                                     entry.className.length ? entry.className : @"runtime",
                                     entry.typeName.length ? entry.typeName : entry.typeCode,
                                     original.length ? original : @"aguardando receiver",
                                     current.length ? current : @"?",
                                     state];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · original",
                                     entry.className.length ? entry.className : @"runtime",
                                     entry.typeName.length ? entry.typeName : entry.typeCode,
                                     current.length ? current : @"aguardando receiver"];
    }
    cell.detailTextLabel.textColor = overridden
        ? (installed ? UIColor.systemCyanColor : UIColor.systemOrangeColor)
        : WAGRMenuSecondaryTextColor();
}

#pragma mark - Browser presentation lifecycle / cells

static void WAGRBrowserDidLoad(id self, SEL _cmd) {
    IMP original = WAGRBrowserOriginalIMP(self, _cmd, gWAGRDidLoadOriginals);
    if (original) ((void (*)(id, SEL))original)(self, _cmd);
    WAGRBrowserUpdateGlassTitle(self);
    WAGRBrowserConfigureSearch(self);
}

static void WAGRBrowserDidLayout(id self, SEL _cmd) {
    IMP original = WAGRBrowserOriginalIMP(self, _cmd, gWAGRDidLayoutOriginals);
    if (original) ((void (*)(id, SEL))original)(self, _cmd);
    WAGRBrowserUpdateGlassTitle(self);
    WAGRBrowserConfigureSearch(self);
}

static void WAGRBrowserWillAppear(id self, SEL _cmd, BOOL animated) {
    IMP original = WAGRBrowserOriginalIMP(self, _cmd, gWAGRWillAppearOriginals);
    if (original) ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    WAGRBrowserUpdateGlassTitle(self);
    WAGRBrowserConfigureSearch(self);
    if (WAGRBrowserUsesBottomSearch(self)) {
        [((UIViewController *)self).navigationController setToolbarHidden:NO animated:animated];
    }
}

static void WAGRBrowserWillDisappear(id self, SEL _cmd, BOOL animated) {
    IMP original = WAGRBrowserOriginalIMP(self, _cmd, gWAGRWillDisappearOriginals);
    if (original) ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    if (WAGRBrowserUsesBottomSearch(self)) {
        [((UIViewController *)self).navigationController setToolbarHidden:YES animated:animated];
    }
}

static UITableViewCell *WAGRBrowserCell(id self,
                                        SEL _cmd,
                                        UITableView *tableView,
                                        NSIndexPath *indexPath) {
    IMP original = WAGRBrowserOriginalIMP(self, _cmd, gWAGRCellOriginals);
    UITableViewCell *cell = original
        ? ((id (*)(id, SEL, id, id))original)(self, _cmd, tableView, indexPath)
        : nil;
    if (!cell) return cell;

    if ([self isKindOfClass:NSClassFromString(@"WAGRABPropsBrowserVC")]) {
        WAGRBrowserPostProcessABCell(self, cell, indexPath);
    } else if ([self isKindOfClass:NSClassFromString(@"WAGRSurfaceBrowserVC")]) {
        WAGRBrowserPostProcessSurfaceCell(self, cell, indexPath);
    }
    return cell;
}

static void WAGRBrowserInstallForClass(NSString *className, BOOL hasSearch, BOOL compactCells) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    WAGRBrowserInstallMethod(cls, @selector(viewDidLoad),
                             (IMP)WAGRBrowserDidLoad, gWAGRDidLoadOriginals);
    WAGRBrowserInstallMethod(cls, @selector(viewDidLayoutSubviews),
                             (IMP)WAGRBrowserDidLayout, gWAGRDidLayoutOriginals);
    if (hasSearch) {
        WAGRBrowserInstallMethod(cls, @selector(viewWillAppear:),
                                 (IMP)WAGRBrowserWillAppear, gWAGRWillAppearOriginals);
        WAGRBrowserInstallMethod(cls, @selector(viewWillDisappear:),
                                 (IMP)WAGRBrowserWillDisappear, gWAGRWillDisappearOriginals);
    }
    if (compactCells) {
        WAGRBrowserInstallMethod(cls, @selector(tableView:cellForRowAtIndexPath:),
                                 (IMP)WAGRBrowserCell, gWAGRCellOriginals);
    }
}

static void WAGRRuntimeBrowsersGlassInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRDidLoadOriginals = [NSMutableDictionary dictionary];
        gWAGRDidLayoutOriginals = [NSMutableDictionary dictionary];
        gWAGRWillAppearOriginals = [NSMutableDictionary dictionary];
        gWAGRWillDisappearOriginals = [NSMutableDictionary dictionary];
        gWAGRCellOriginals = [NSMutableDictionary dictionary];

        WAGRBrowserInstallForClass(@"WAGRMainSettingsVC", NO, NO);
        WAGRBrowserInstallForClass(@"WAGRABPropsRootVC", NO, NO);
        WAGRBrowserInstallForClass(@"WAGRABPropsBrowserVC", YES, YES);
        WAGRBrowserInstallForClass(@"WAGRSurfaceBrowserVC", YES, YES);
    });
}

__attribute__((constructor))
static void WAGRRuntimeBrowsersGlassCtor(void) {
    @autoreleasepool {
        WAGRRuntimeBrowsersGlassInstall();
    }
}