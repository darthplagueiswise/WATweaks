#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>

#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"

static const void *kWAGRNativeABEntryKey = &kWAGRNativeABEntryKey;
static const void *kWAGRNativeSurfaceEntryKey = &kWAGRNativeSurfaceEntryKey;

static void (*orig_WAGRABViewDidLoad)(id, SEL) = NULL;
static void (*orig_WAGRSurfaceViewDidLoad)(id, SEL) = NULL;
static void (*orig_WAGRRuntimeGatesViewDidLoad)(id, SEL) = NULL;
static void (*orig_WAGRABRootViewDidLoad)(id, SEL) = NULL;

static id WAGRNativeKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRNativeSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static UIFont *WAGRNativeRowTitleFont(void) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    return [UIFont systemFontOfSize:MAX(16.0, font.pointSize) weight:UIFontWeightRegular];
}

static UIFont *WAGRNativeRowDetailFont(void) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    return [UIFont systemFontOfSize:MAX(13.0, font.pointSize) weight:UIFontWeightRegular];
}

static void WAGRNativeStyleController(UITableViewController *controller, BOOL hasSearch) {
    if (!controller) return;
    controller.tableView.estimatedRowHeight = 68.0;
    controller.tableView.rowHeight = UITableViewAutomaticDimension;
    controller.tableView.sectionHeaderHeight = 16.0;
    controller.tableView.sectionFooterHeight = 5.0;
    if (@available(iOS 15.0, *)) controller.tableView.sectionHeaderTopPadding = 0.0;

    if (hasSearch) {
        controller.navigationItem.hidesSearchBarWhenScrolling = YES;
        if (@available(iOS 16.0, *)) {
            controller.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
        }
    }
}

static NSString *WAGRNativeNoHeader(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return nil;
}

static CGFloat WAGRNativeHeaderHeight(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return 16.0;
}

static CGFloat WAGRNativeFooterHeight(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return 5.0;
}

static NSArray<NSString *> *WAGRNativeTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [(query ?: @"").lowercaseString componentsSeparatedByCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

static NSInteger WAGRNativeABPreferenceRank(WAGRABPropEntry *entry) {
    NSString *name = entry.className ?: @"";
    if ([name isEqualToString:@"WAABProperties"]) return 0;
    if ([name containsString:@"WAABProperties"]) return 1;
    if ([name containsString:@"FOAWAABProperties"]) return 2;
    return 3;
}

static NSDictionary *WAGRNativeEntryForAB(id self, WAGRABPropEntry *entry) {
    NSDictionary *index = WAGRNativeKVC(self, @"nativeEntriesBySelector");
    id value = entry.selectorName.length ? index[entry.selectorName] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static uint64_t WAGRNativeSpecifierFromMC(NSDictionary *mc) {
    id value = mc[@"param_specifier_hex"];
    if ([value isKindOfClass:NSNumber.class]) return [value unsignedLongLongValue];
    if (![value isKindOfClass:NSString.class]) return 0;
    return strtoull([(NSString *)value UTF8String] ?: "0", NULL, 0);
}

static NSString *WAGRNativeMCName(NSDictionary *mc) {
    NSString *config = [mc[@"config_name"] isKindOfClass:NSString.class] ? mc[@"config_name"] : nil;
    NSString *parameter = [mc[@"parameter_name"] isKindOfClass:NSString.class] ? mc[@"parameter_name"] : nil;
    if (config.length && parameter.length) return [NSString stringWithFormat:@"%@.%@", config, parameter];
    if (parameter.length) return parameter;
    return WAGRMobileConfigRuntimeNameForSpecifier(WAGRNativeSpecifierFromMC(mc));
}

static BOOL WAGRNativeBoolFromWireValue(id value, BOOL *known) {
    if (known) *known = NO;
    if ([value isKindOfClass:NSNumber.class]) {
        if (known) *known = YES;
        return [value boolValue];
    }
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *lower = [(NSString *)value lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]) {
        if (known) *known = YES;
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]) {
        if (known) *known = YES;
        return NO;
    }
    return NO;
}

#pragma mark - WAAB account/runtime filter

static void WAGRNativeABApplyFilter(id self, SEL _cmd) {
    (void)_cmd;
    UISearchController *search = WAGRNativeKVC(self, @"searchController");
    NSArray<WAGRABPropEntry *> *allEntries = WAGRNativeKVC(self, @"allEntries") ?: @[];
    NSDictionary *nativeIndex = WAGRNativeKVC(self, @"nativeEntriesBySelector") ?: @{};
    NSInteger scope = search.searchBar.selectedScopeButtonIndex;
    NSArray<NSString *> *tokens = WAGRNativeTokens(search.searchBar.text ?: @"");

    NSMutableDictionary<NSString *, WAGRABPropEntry *> *bestBySelector = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in allEntries) {
        if (!entry.selectorName.length) continue;
        NSDictionary *native = [nativeIndex[entry.selectorName] isKindOfClass:NSDictionary.class]
            ? nativeIndex[entry.selectorName] : nil;
        BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);

        if (scope == 0 && !native) continue;      // Conta: only current gabp.*p entries.
        if (scope == 2 && !overridden) continue; // Overrides.

        NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? native[@"mobileconfig"] : @{};
        NSString *runtimeMCName = WAGRNativeMCName(mc) ?: @"";
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
            entry.selectorName ?: @"", entry.className ?: @"", entry.categoryName ?: @"",
            native[@"code"] ?: @"", native[@"value"] ?: @"", runtimeMCName].lowercaseString;
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (![haystack containsString:token]) { matches = NO; break; }
        }
        if (!matches) continue;

        WAGRABPropEntry *existing = bestBySelector[entry.selectorName];
        if (!existing || WAGRNativeABPreferenceRank(entry) < WAGRNativeABPreferenceRank(existing)) {
            bestBySelector[entry.selectorName] = entry;
        }
    }

    NSArray<WAGRABPropEntry *> *filtered = [bestBySelector.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(WAGRABPropEntry *left, WAGRABPropEntry *right) {
            NSString *leftFamily = WAGRLiveRuntimeFamilyForSelector(left.selectorName, left.className) ?: @"";
            NSString *rightFamily = WAGRLiveRuntimeFamilyForSelector(right.selectorName, right.className) ?: @"";
            NSComparisonResult result = [leftFamily localizedCaseInsensitiveCompare:rightFamily];
            if (result != NSOrderedSame) return result;
            return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
        }];

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in filtered) {
        NSString *family = WAGRLiveRuntimeFamilyForSelector(entry.selectorName, entry.className);
        if (!family.length) family = @"Runtime";
        if (!groups[family]) groups[family] = [NSMutableArray array];
        [groups[family] addObject:entry];
    }
    NSArray<NSString *> *sectionKeys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    WAGRNativeSetKVC(self, @"sectionKeys", sectionKeys ?: @[]);
    WAGRNativeSetKVC(self, @"sections", groups ?: @{});

    WAGRABPropsNativeSnapshot *snapshot = WAGRNativeKVC(self, @"nativeSnapshot");
    NSUInteger cacheCount = snapshot.numericPropCount;
    search.searchBar.placeholder = cacheCount
        ? [NSString stringWithFormat:@"Buscar · %lu cache · %lu métodos", (unsigned long)cacheCount, (unsigned long)allEntries.count]
        : [NSString stringWithFormat:@"Buscar · %lu métodos runtime", (unsigned long)allEntries.count];

    UIViewController *controller = (UIViewController *)self;
    controller.title = scope == 0 ? @"WAAB · Conta" : (scope == 1 ? @"WAAB · Runtime" : @"WAAB · Overrides");
    [((UITableViewController *)self).tableView reloadData];
}

static void WAGRNativeABScopeChanged(id self, SEL _cmd, UISearchBar *searchBar, NSInteger index) {
    (void)_cmd; (void)searchBar; (void)index;
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"applyCurrentFilter"));
}

#pragma mark - Cells

static WAGRABPropEntry *WAGRNativeABEntryAt(id self, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    return [self respondsToSelector:selector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(self, selector, indexPath) : nil;
}

static WAGREntry *WAGRNativeSurfaceEntryAt(id self, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    return [self respondsToSelector:selector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(self, selector, indexPath) : nil;
}

static UITableViewCell *WAGRNativeABCell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    static NSString *reuse = @"WAGRNativeABCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];

    WAGRABPropEntry *entry = WAGRNativeABEntryAt(self, indexPath);
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"abprop");
    cell.textLabel.font = WAGRNativeRowTitleFont();
    cell.detailTextLabel.font = WAGRNativeRowDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (!entry) return cell;

    NSArray *runtimeObjects = WAGRNativeKVC(self, @"runtimeObjects") ?: @[];
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, runtimeObjects, &raw) ?: @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod);
    NSDictionary *native = WAGRNativeEntryForAB(self, entry);
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class] ? native[@"mobileconfig"] : @{};

    cell.textLabel.text = entry.selectorName ?: @"?";
    NSMutableString *detail = [NSMutableString stringWithString:current];
    if (overridden) [detail appendString:@" · Override"];
    if (native) [detail appendFormat:@" · AB %@", native[@"code"] ?: @"?"];

    BOOL cacheMismatch = NO;
    if (!overridden && native && WAGRRuntimeValueTypeIsBoolean(entry.typeCode) &&
        [raw respondsToSelector:@selector(boolValue)]) {
        BOOL known = NO;
        BOOL cacheValue = WAGRNativeBoolFromWireValue(native[@"value"], &known);
        if (known && cacheValue != [raw boolValue]) {
            cacheMismatch = YES;
            [detail appendFormat:@" · cache %@", cacheValue ? @"YES" : @"NO"];
        }
    }

    NSString *mcName = WAGRNativeMCName(mc);
    if (mcName.length) [detail appendFormat:@"\n%@", mcName];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = cacheMismatch ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class]
            ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:NSSelectorFromString(@"wagr_nativeABSwitchChanged:")
              forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRNativeABEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = UIColor.systemGreenColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRNativeABSwitchChanged(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRNativeABEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName, entry.classMethod, entry.typeCode, @(sender.isOn));
    if (!WAGRRuntimeValueInstallHook(entry.className, entry.selectorName, entry.classMethod, entry.typeCode)) {
        WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.classMethod);
    }
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"applyCurrentFilter"));
}

static UITableViewCell *WAGRNativeSurfaceCell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    static NSString *reuse = @"WAGRNativeSurfaceCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];

    WAGREntry *entry = WAGRNativeSurfaceEntryAt(self, indexPath);
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"runtime");
    cell.textLabel.font = WAGRNativeRowTitleFont();
    cell.detailTextLabel.font = WAGRNativeRowDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (!entry) return cell;

    id raw = nil;
    NSString *current = ((id (*)(id, SEL, id, id *))objc_msgSend)(
        self, NSSelectorFromString(@"currentForEntry:raw:"), entry, &raw) ?: @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.isClassMethod);

    cell.textLabel.text = entry.selectorName ?: @"?";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
        entry.className ?: @"Runtime", current, overridden ? @" · Override" : @""];

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class]
            ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:NSSelectorFromString(@"wagr_nativeSurfaceSwitchChanged:")
              forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRNativeSurfaceEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = UIColor.systemGreenColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRNativeSurfaceSwitchChanged(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    WAGREntry *entry = objc_getAssociatedObject(sender, kWAGRNativeSurfaceEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode, @(sender.isOn));
    if (!WAGRRuntimeValueInstallHook(entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode)) {
        WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.isClassMethod);
    }
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"applyCurrentFilter"));
}

static UITableViewCell *WAGRNativeRuntimeFamilyCell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    NSArray<WAGRSurfaceSpec *> *surfaces = WAGRNativeKVC(self, @"visibleSurfaces") ?: @[];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)surfaces.count) return [UITableViewCell new];
    WAGRSurfaceSpec *surface = surfaces[(NSUInteger)indexPath.row];
    static NSString *reuse = @"WAGRNativeRuntimeFamilyCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGRMenuApplyCellStyle(cell, indexPath.row, surface.surfaceID ?: surface.title);
    cell.textLabel.font = WAGRNativeRowTitleFont();
    cell.detailTextLabel.font = WAGRNativeRowDetailFont();
    cell.textLabel.text = surface.title ?: @"Runtime";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu getters · %lu classes",
        (unsigned long)surface.runtimeEntryCount, (unsigned long)surface.runtimeClassCount];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

static UITableViewCell *WAGRNativeRootCell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    NSArray *sections = WAGRNativeKVC(self, @"sections");
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)sections.count) return [UITableViewCell new];
    NSArray *rows = sections[(NSUInteger)indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)rows.count) return [UITableViewCell new];
    id row = rows[(NSUInteger)indexPath.row];
    NSString *title = WAGRNativeKVC(row, @"title") ?: @"";

    static NSString *reuse = @"WAGRNativeABRootCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGRMenuApplyCellStyle(cell, indexPath.row, title);
    cell.textLabel.font = WAGRNativeRowTitleFont();
    cell.detailTextLabel.font = WAGRNativeRowDetailFont();
    cell.textLabel.text = title;

    NSString *detail = @"";
    if ([title hasPrefix:@"Snapshot nativo"]) detail = @"Cache da conta, Fetch e export";
    else if ([title containsString:@"WAABProperties"]) detail = @"Getters vivos e valores da conta";
    else if ([title containsString:@"famílias"]) detail = @"Classes e selectors carregados";
    else if ([title containsString:@"Private Experimentation"]) detail = @"Fluxo nativo de experimentação";
    else if ([title containsString:@"Context"]) detail = @"Contexto, cache e hooks";
    else if ([title containsString:@"Log"]) detail = @"Logs da sessão";
    cell.detailTextLabel.text = detail;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - viewDidLoad wrappers

static void WAGRNativeABViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRABViewDidLoad) orig_WAGRABViewDidLoad(self, _cmd);
    WAGRNativeStyleController((UITableViewController *)self, YES);
    UISearchController *search = WAGRNativeKVC(self, @"searchController");
    search.searchBar.scopeButtonTitles = @[ @"Conta", @"Runtime", @"Overrides" ];
    search.searchBar.selectedScopeButtonIndex = 0;
    search.searchBar.delegate = self;
    ((UIViewController *)self).title = @"WAAB · Conta";
}

static void WAGRNativeSurfaceViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRSurfaceViewDidLoad) orig_WAGRSurfaceViewDidLoad(self, _cmd);
    WAGRNativeStyleController((UITableViewController *)self, YES);
}

static void WAGRNativeRuntimeGatesViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRRuntimeGatesViewDidLoad) orig_WAGRRuntimeGatesViewDidLoad(self, _cmd);
    WAGRNativeStyleController((UITableViewController *)self, YES);
}

static void WAGRNativeABRootViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRABRootViewDidLoad) orig_WAGRABRootViewDidLoad(self, _cmd);
    WAGRNativeStyleController((UITableViewController *)self, NO);
    ((UIViewController *)self).navigationItem.rightBarButtonItem = nil;
}

#pragma mark - Installation

static void WAGRNativeReplaceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method && method_getImplementation(method) != replacement) method_setImplementation(method, replacement);
}

static IMP WAGRNativeReplaceAndCapture(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    IMP current = method_getImplementation(method);
    if (current != replacement) method_setImplementation(method, replacement);
    return current;
}

static void WAGRNativeAddSectionHeights(Class cls) {
    if (!cls) return;
    SEL header = @selector(tableView:heightForHeaderInSection:);
    SEL footer = @selector(tableView:heightForFooterInSection:);
    if (!class_addMethod(cls, header, (IMP)WAGRNativeHeaderHeight, "d@:@q")) {
        WAGRNativeReplaceMethod(cls, header, (IMP)WAGRNativeHeaderHeight);
    }
    if (!class_addMethod(cls, footer, (IMP)WAGRNativeFooterHeight, "d@:@q")) {
        WAGRNativeReplaceMethod(cls, footer, (IMP)WAGRNativeFooterHeight);
    }
}

__attribute__((constructor))
static void WAGRRuntimeBrowserNativeUICtor(void) {
    @autoreleasepool {
        Class ab = NSClassFromString(@"WAGRABPropsBrowserVC");
        Class surface = NSClassFromString(@"WAGRSurfaceBrowserVC");
        Class gates = NSClassFromString(@"WAGRRuntimeGatesVC");
        Class root = NSClassFromString(@"WAGRABPropsRootVC");

        if (ab) {
            orig_WAGRABViewDidLoad = (void (*)(id, SEL))WAGRNativeReplaceAndCapture(ab, @selector(viewDidLoad), (IMP)WAGRNativeABViewDidLoad);
            WAGRNativeReplaceMethod(ab, NSSelectorFromString(@"applyCurrentFilter"), (IMP)WAGRNativeABApplyFilter);
            WAGRNativeReplaceMethod(ab, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRNativeABCell);
            WAGRNativeReplaceMethod(ab, @selector(tableView:titleForHeaderInSection:), (IMP)WAGRNativeNoHeader);
            WAGRNativeReplaceMethod(ab, @selector(tableView:titleForFooterInSection:), (IMP)WAGRNativeNoHeader);
            WAGRNativeAddSectionHeights(ab);
            class_addMethod(ab, NSSelectorFromString(@"wagr_nativeABSwitchChanged:"), (IMP)WAGRNativeABSwitchChanged, "v@:@");
            class_addMethod(ab, @selector(searchBar:selectedScopeButtonIndexDidChange:), (IMP)WAGRNativeABScopeChanged, "v@:@q");
        }

        if (surface) {
            orig_WAGRSurfaceViewDidLoad = (void (*)(id, SEL))WAGRNativeReplaceAndCapture(surface, @selector(viewDidLoad), (IMP)WAGRNativeSurfaceViewDidLoad);
            WAGRNativeReplaceMethod(surface, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRNativeSurfaceCell);
            WAGRNativeReplaceMethod(surface, @selector(tableView:titleForHeaderInSection:), (IMP)WAGRNativeNoHeader);
            WAGRNativeReplaceMethod(surface, @selector(tableView:titleForFooterInSection:), (IMP)WAGRNativeNoHeader);
            WAGRNativeAddSectionHeights(surface);
            class_addMethod(surface, NSSelectorFromString(@"wagr_nativeSurfaceSwitchChanged:"), (IMP)WAGRNativeSurfaceSwitchChanged, "v@:@");
        }

        if (gates) {
            orig_WAGRRuntimeGatesViewDidLoad = (void (*)(id, SEL))WAGRNativeReplaceAndCapture(gates, @selector(viewDidLoad), (IMP)WAGRNativeRuntimeGatesViewDidLoad);
            WAGRNativeReplaceMethod(gates, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRNativeRuntimeFamilyCell);
            WAGRNativeAddSectionHeights(gates);
        }

        if (root) {
            orig_WAGRABRootViewDidLoad = (void (*)(id, SEL))WAGRNativeReplaceAndCapture(root, @selector(viewDidLoad), (IMP)WAGRNativeABRootViewDidLoad);
            WAGRNativeReplaceMethod(root, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRNativeRootCell);
            WAGRNativeReplaceMethod(root, @selector(tableView:titleForHeaderInSection:), (IMP)WAGRNativeNoHeader);
            WAGRNativeReplaceMethod(root, @selector(tableView:titleForFooterInSection:), (IMP)WAGRNativeNoHeader);
            WAGRNativeAddSectionHeights(root);
        }
    }
}
