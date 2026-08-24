#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stdlib.h>

#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"

static const void *kWAGRNativeABEntryKey = &kWAGRNativeABEntryKey;
static const void *kWAGRNativeSurfaceEntryKey = &kWAGRNativeSurfaceEntryKey;
static const void *kWAGRNativeTitlePrimaryKey = &kWAGRNativeTitlePrimaryKey;
static const void *kWAGRNativeTitleSecondaryKey = &kWAGRNativeTitleSecondaryKey;

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

// The account browser is a dense diagnostic/settings list. Do not inherit the
// user's Body Dynamic Type size here: on the current iPhone it made selector
// names materially larger than WhatsApp's own Settings rows.
static UIFont *WAGRNativeRowTitleFont(void) {
    return [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
}

static UIFont *WAGRNativeRowDetailFont(void) {
    return [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
}

static void WAGRNativeSetCenteredTitle(UIViewController *controller,
                                       NSString *title,
                                       NSString *subtitle) {
    if (!controller) return;
    UILabel *primary = objc_getAssociatedObject(controller, kWAGRNativeTitlePrimaryKey);
    UILabel *secondary = objc_getAssociatedObject(controller, kWAGRNativeTitleSecondaryKey);
    if (!primary || !secondary || !controller.navigationItem.titleView) {
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 176, 42)];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        [container.widthAnchor constraintEqualToConstant:176].active = YES;
        [container.heightAnchor constraintEqualToConstant:42].active = YES;

        primary = [UILabel new];
        primary.translatesAutoresizingMaskIntoConstraints = NO;
        primary.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
        primary.textColor = UIColor.labelColor;
        primary.textAlignment = NSTextAlignmentCenter;
        primary.adjustsFontSizeToFitWidth = YES;
        primary.minimumScaleFactor = 0.86;

        secondary = [UILabel new];
        secondary.translatesAutoresizingMaskIntoConstraints = NO;
        secondary.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
        secondary.textColor = UIColor.secondaryLabelColor;
        secondary.textAlignment = NSTextAlignmentCenter;
        secondary.adjustsFontSizeToFitWidth = YES;
        secondary.minimumScaleFactor = 0.82;

        [container addSubview:primary];
        [container addSubview:secondary];
        [NSLayoutConstraint activateConstraints:@[
            [primary.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [primary.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [primary.topAnchor constraintEqualToAnchor:container.topAnchor constant:3],
            [secondary.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [secondary.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [secondary.topAnchor constraintEqualToAnchor:primary.bottomAnchor constant:1],
            [secondary.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-2],
        ]];
        controller.navigationItem.titleView = container;
        objc_setAssociatedObject(controller, kWAGRNativeTitlePrimaryKey, primary,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kWAGRNativeTitleSecondaryKey, secondary,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    primary.text = title ?: @"";
    secondary.text = subtitle ?: @"";
    controller.navigationItem.accessibilityLabel = subtitle.length
        ? [NSString stringWithFormat:@"%@, %@", title ?: @"", subtitle]
        : title;
    // titleView is inside UINavigationBar, so iOS 26 supplies the native
    // Liquid Glass navigation chrome. Do not add a second glass capsule here.
}

static void WAGRNativeStyleController(UITableViewController *controller, BOOL hasSearch) {
    if (!controller) return;
    controller.tableView.estimatedRowHeight = 54.0;
    controller.tableView.rowHeight = UITableViewAutomaticDimension;
    controller.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    controller.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
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
    (void)_cmd; (void)table;
    if ([self isKindOfClass:NSClassFromString(@"WAGRABPropsBrowserVC")]) {
        UISearchController *search = WAGRNativeKVC(self, @"searchController");
        // Conta and Overrides are deliberately one inset-grouped section. Runtime
        // may still have real family sections and gets normal inter-group spacing.
        if (search.searchBar.selectedScopeButtonIndex != 1) return section == 0 ? 10.0 : 0.01;
        return section == 0 ? 10.0 : 22.0;
    }
    return section == 0 ? 10.0 : 22.0;
}

static CGFloat WAGRNativeFooterHeight(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return 0.01;
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

static NSString *WAGRNativeParameterPart(NSString *fullName) {
    if (!fullName.length) return nil;
    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && NSMaxRange(dot) < fullName.length) {
        return [fullName substringFromIndex:NSMaxRange(dot)];
    }
    return fullName;
}

static BOOL WAGRNativeBoolFromWireValue(id value, BOOL *known) {
    if (known) *known = NO;
    if ([value isKindOfClass:NSNumber.class]) {
        if (known) *known = YES;
        return [value boolValue];
    }
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *lower = [(NSString *)value lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] ||
        [lower isEqualToString:@"yes"]) {
        if (known) *known = YES;
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] ||
        [lower isEqualToString:@"no"]) {
        if (known) *known = YES;
        return NO;
    }
    return NO;
}

// WAMCEvaluation encodes the semantic parameter family in bits 48..53:
// 1=bool, 2=int64, 3=string, 4=double. That metadata is authoritative for
// how an account ABProp should be presented. The Objective-C getter ABI remains
// authoritative for how WAGRRuntimeValueStore installs the actual hook.
static uint8_t WAGRNativeABSemanticType(WAGRABPropEntry *entry, NSDictionary *native) {
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? native[@"mobileconfig"] : nil;
    uint8_t nativeType = [mc[@"native_type"] respondsToSelector:@selector(unsignedCharValue)]
        ? [mc[@"native_type"] unsignedCharValue] : 0;
    if (nativeType >= 1 && nativeType <= 4) return nativeType;

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) return 1;
    if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
        WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode)) return 2;
    if (WAGRRuntimeValueTypeIsObject(entry.typeCode)) return 3;
    if (WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) return 4;
    return 0;
}

static NSString *WAGRNativeABDisplayName(WAGRABPropEntry *entry,
                                         NSDictionary *native,
                                         NSDictionary *mc) {
    NSString *nativeName = [native[@"name"] isKindOfClass:NSString.class]
        ? native[@"name"] : nil;
    if (nativeName.length && ![nativeName hasPrefix:@"ABProp "]) return nativeName;

    NSString *schemaName = WAGRNativeParameterPart(WAGRNativeMCName(mc));
    if (schemaName.length) return schemaName;
    return entry.selectorName.length ? entry.selectorName : @"ABProp";
}

static NSString *WAGRNativeABDisplayValue(uint8_t semanticType,
                                          id raw,
                                          NSString *runtimeText,
                                          NSDictionary *native) {
    if (semanticType == 1) {
        if ([raw respondsToSelector:@selector(boolValue)]) return [raw boolValue] ? @"YES" : @"NO";
        BOOL known = NO;
        BOOL value = WAGRNativeBoolFromWireValue(native[@"value"], &known);
        if (known) return value ? @"YES" : @"NO";
    }
    if (raw && raw != NSNull.null) return [raw description] ?: (runtimeText ?: @"?");
    if (native[@"value"] && native[@"value"] != NSNull.null) return [native[@"value"] description] ?: @"?";
    return runtimeText ?: @"?";
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

        if (scope == 0 && !native) continue;
        if (scope == 2 && !overridden) continue;

        NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? native[@"mobileconfig"] : @{};
        NSString *runtimeMCName = WAGRNativeMCName(mc) ?: @"";
        NSString *nativeDisplayName = [native[@"name"] isKindOfClass:NSString.class]
            ? native[@"name"] : @"";
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@",
            entry.selectorName ?: @"", entry.className ?: @"", entry.categoryName ?: @"",
            native[@"code"] ?: @"", native[@"value"] ?: @"", runtimeMCName,
            nativeDisplayName].lowercaseString;
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
            if (scope == 1) {
                NSString *leftFamily = WAGRLiveRuntimeFamilyForSelector(left.selectorName, left.className) ?: @"";
                NSString *rightFamily = WAGRLiveRuntimeFamilyForSelector(right.selectorName, right.className) ?: @"";
                NSComparisonResult familyResult = [leftFamily localizedCaseInsensitiveCompare:rightFamily];
                if (familyResult != NSOrderedSame) return familyResult;
            }
            return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
        }];

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups = [NSMutableDictionary dictionary];
    NSArray<NSString *> *sectionKeys = nil;
    if (scope == 1) {
        for (WAGRABPropEntry *entry in filtered) {
            NSString *family = WAGRLiveRuntimeFamilyForSelector(entry.selectorName, entry.className);
            if (!family.length) family = @"Runtime";
            if (!groups[family]) groups[family] = [NSMutableArray array];
            [groups[family] addObject:entry];
        }
        sectionKeys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    } else {
        // A Conta is one native inset-grouped list. Previously every hidden
        // runtime-family section became its own rounded card, which produced the
        // large black gaps visible in the screenshot.
        groups[@"Conta"] = [filtered mutableCopy] ?: [NSMutableArray array];
        sectionKeys = @[ @"Conta" ];
    }
    WAGRNativeSetKVC(self, @"sectionKeys", sectionKeys ?: @[]);
    WAGRNativeSetKVC(self, @"sections", groups ?: @{});

    WAGRABPropsNativeSnapshot *snapshot = WAGRNativeKVC(self, @"nativeSnapshot");
    NSUInteger cacheCount = snapshot.numericPropCount;
    search.searchBar.placeholder = cacheCount
        ? [NSString stringWithFormat:@"Buscar em %lu ABProps", (unsigned long)cacheCount]
        : [NSString stringWithFormat:@"Buscar em %lu getters", (unsigned long)allEntries.count];

    UIViewController *controller = (UIViewController *)self;
    NSString *title = scope == 0 ? @"WAAB · Conta" : (scope == 1 ? @"WAAB · Runtime" : @"WAAB · Overrides");
    NSString *subtitle = nil;
    BOOL fetching = [WAGRNativeKVC(self, @"fetching") boolValue];
    NSString *lastFetch = [WAGRNativeKVC(self, @"lastFetchNote") isKindOfClass:NSString.class]
        ? WAGRNativeKVC(self, @"lastFetchNote") : nil;
    if (fetching) {
        subtitle = cacheCount ? [NSString stringWithFormat:@"%lu ABProps · buscando…", (unsigned long)cacheCount]
                              : @"Buscando ABProps…";
    } else if (scope == 0) {
        if (tokens.count) {
            subtitle = [NSString stringWithFormat:@"%lu resultados · %lu ABProps",
                (unsigned long)filtered.count, (unsigned long)cacheCount];
        } else if ([lastFetch containsString:@"recebeu delta"] || [lastFetch containsString:@"cache atualizado"]) {
            subtitle = [NSString stringWithFormat:@"%lu ABProps · cache atualizado", (unsigned long)cacheCount];
        } else if ([lastFetch containsString:@"nenhum delta"] || [lastFetch containsString:@"request enviado"]) {
            subtitle = [NSString stringWithFormat:@"%lu ABProps · request concluído", (unsigned long)cacheCount];
        } else {
            subtitle = [NSString stringWithFormat:@"%lu ABProps · %lu correlacionadas",
                (unsigned long)cacheCount, (unsigned long)filtered.count];
        }
    } else if (scope == 2) {
        subtitle = [NSString stringWithFormat:@"%lu overrides", (unsigned long)filtered.count];
    } else {
        subtitle = [NSString stringWithFormat:@"%lu getters", (unsigned long)filtered.count];
    }
    controller.title = title;
    WAGRNativeSetCenteredTitle(controller, title, subtitle);
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
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!entry) return cell;

    NSArray *runtimeObjects = WAGRNativeKVC(self, @"runtimeObjects") ?: @[];
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, runtimeObjects, &raw) ?: @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod);
    NSDictionary *native = WAGRNativeEntryForAB(self, entry);
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class] ? native[@"mobileconfig"] : @{};
    uint8_t semanticType = WAGRNativeABSemanticType(entry, native ?: @{});

    cell.textLabel.text = WAGRNativeABDisplayName(entry, native ?: @{}, mc);
    id effectiveRaw = overridden ? forced : raw;
    NSString *displayValue = WAGRNativeABDisplayValue(semanticType, effectiveRaw, current, native ?: @{});
    NSMutableString *detail = [NSMutableString stringWithString:displayValue ?: @"?"];
    if (native) [detail appendFormat:@" · AB %@", native[@"code"] ?: @"?"];
    if (overridden) [detail appendString:@" · override"];

    BOOL cacheMismatch = NO;
    if (!overridden && native && semanticType == 1 && [raw respondsToSelector:@selector(boolValue)]) {
        BOOL known = NO;
        BOOL cacheValue = WAGRNativeBoolFromWireValue(native[@"value"], &known);
        if (known && cacheValue != [raw boolValue]) cacheMismatch = YES;
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = overridden ? UIColor.systemBlueColor
        : (cacheMismatch ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor);

    if (semanticType == 1) {
        UISwitch *toggle = [UISwitch new];
        [toggle addTarget:self action:NSSelectorFromString(@"wagr_nativeABSwitchChanged:")
          forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(toggle, kWAGRNativeABEntryKey, entry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        BOOL known = NO;
        BOOL on = NO;
        if (overridden && [forced respondsToSelector:@selector(boolValue)]) {
            on = [forced boolValue];
            known = YES;
        } else if ([raw respondsToSelector:@selector(boolValue)]) {
            on = [raw boolValue];
            known = YES;
        } else if (native) {
            on = WAGRNativeBoolFromWireValue(native[@"value"], &known);
        }
        toggle.on = known ? on : NO;
        // WhatsApp/native value = green. WATweaks forced value = blue.
        toggle.onTintColor = overridden ? UIColor.systemBlueColor : UIColor.systemGreenColor;
        cell.accessoryView = toggle;
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
    // Use the getter's real ABI typeCode for the hook. Semantic bool only controls
    // the UI/value we request; it must never lie about the Objective-C ABI.
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, @(sender.isOn));
    if (!WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                     entry.classMethod, entry.typeCode)) {
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
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detailTextLabel.numberOfLines = 1;
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
        entry.className ?: @"Runtime", current, overridden ? @" · override" : @""];
    cell.detailTextLabel.textColor = overridden ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [UISwitch new];
        [toggle addTarget:self action:NSSelectorFromString(@"wagr_nativeSurfaceSwitchChanged:")
          forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(toggle, kWAGRNativeSurfaceEntryKey, entry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = overridden ? UIColor.systemBlueColor : UIColor.systemGreenColor;
        cell.accessoryView = toggle;
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
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.isClassMethod, entry.typeCode, @(sender.isOn));
    if (!WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                     entry.isClassMethod, entry.typeCode)) {
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
    WAGRNativeSetCenteredTitle((UIViewController *)self, @"WAAB · Conta", @"Carregando ABProps…");
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
