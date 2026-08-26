#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>

#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

/*
 * Final runtime-browser interaction layer.
 *
 * This is intentionally late because older compatibility renderers also touch
 * WAGRSurfaceBrowserVC. The late layer must therefore be BOTH fast and safe:
 *
 *  - 110 ms debounced filtering, cached lowercase haystacks;
 *  - exact class + selector receiver resolution only;
 *  - no object_getIvar / class_copyIvarList graph walking;
 *  - no alloc/init of arbitrary WhatsApp classes;
 *  - no "same selector on any class" fallback;
 *  - pending = persisted override whose exact hook is not installed yet;
 *  - compact single-line selector rows with typed inline controls.
 *
 * If the exact receiver is not directly reachable from the browser, the
 * RuntimeValueStore hook captures the real receiver weakly when WhatsApp invokes
 * that exact getter naturally. WAGRRuntimeValueRead(..., nil, ...) can then use
 * that captured receiver without retaining or traversing WhatsApp object graphs.
 */

static const void *kWAGRFastSurfaceEntryKey = &kWAGRFastSurfaceEntryKey;
static const void *kWAGRFastSurfaceHaystackKey = &kWAGRFastSurfaceHaystackKey;
static const void *kWAGRFastSurfaceGenerationKey = &kWAGRFastSurfaceGenerationKey;
static const void *kWAGRFastSurfaceReceiverCacheKey = &kWAGRFastSurfaceReceiverCacheKey;
static const void *kWAGRFastABGenerationKey = &kWAGRFastABGenerationKey;

static id WAGRFastKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRFastSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static UITableViewCell *WAGRFastOwningCell(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:UITableViewCell.class]) return (UITableViewCell *)cursor;
    }
    return nil;
}

static void WAGRFastReloadControlRow(id self, UIView *control) {
    UITableView *table = [self isKindOfClass:UITableViewController.class]
        ? ((UITableViewController *)self).tableView : nil;
    UITableViewCell *cell = WAGRFastOwningCell(control);
    NSIndexPath *path = (table && cell) ? [table indexPathForCell:cell] : nil;
    if (path) [table reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Exact live receiver resolution

static BOOL WAGRFastExactReceiver(id object, Class cls, SEL selector) {
    return object && cls && [object isKindOfClass:cls] && [object respondsToSelector:selector];
}

static id WAGRFastFindInViewTree(UIView *view, Class cls, SEL selector) {
    if (!view) return nil;
    if (WAGRFastExactReceiver(view, cls, selector)) return view;
    for (UIView *subview in view.subviews) {
        id found = WAGRFastFindInViewTree(subview, cls, selector);
        if (found) return found;
    }
    return nil;
}

static id WAGRFastFindInControllerTree(UIViewController *controller, Class cls, SEL selector) {
    if (!controller) return nil;
    if (WAGRFastExactReceiver(controller, cls, selector)) return controller;

    id inView = WAGRFastFindInViewTree(controller.viewIfLoaded, cls, selector);
    if (inView) return inView;

    if (controller.presentedViewController) {
        id found = WAGRFastFindInControllerTree(controller.presentedViewController, cls, selector);
        if (found) return found;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers.reverseObjectEnumerator) {
            id found = WAGRFastFindInControllerTree(child, cls, selector);
            if (found) return found;
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)controller).viewControllers ?: @[]) {
            id found = WAGRFastFindInControllerTree(child, cls, selector);
            if (found) return found;
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        id found = WAGRFastFindInControllerTree(child, cls, selector);
        if (found) return found;
    }
    return nil;
}

static id WAGRFastSingletonReceiver(Class cls, SEL selector) {
    if (!cls || !selector) return nil;
    for (NSString *name in @[ @"shared", @"sharedInstance", @"current", @"defaultInstance",
                               @"defaultManager", @"manager", @"provider", @"properties",
                               @"instance", @"getInstance" ]) {
        SEL factory = NSSelectorFromString(name);
        Method method = class_getClassMethod(cls, factory);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char raw[32] = {0};
        method_getReturnType(method, raw, sizeof(raw));
        const char *cursor = raw;
        while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
        if (*cursor != '@') continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)((id)cls, factory);
            if (WAGRFastExactReceiver(value, cls, selector)) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static id WAGRFastSurfaceReceiver(id self, SEL _cmd, WAGREntry *entry) {
    (void)_cmd;
    if (!entry || entry.isClassMethod) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    if (!cls || !selector) return nil;

    NSMutableDictionary *cache = objc_getAssociatedObject(self, kWAGRFastSurfaceReceiverCacheKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, kWAGRFastSurfaceReceiverCacheKey, cache,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", entry.className ?: @"", entry.selectorName ?: @""];
    id cached = cache[cacheKey];
    if (cached && cached != NSNull.null && WAGRFastExactReceiver(cached, cls, selector)) return cached;

    NSArray *runtimeObjects = WAGRFastKVC(self, @"runtimeObjects") ?: @[];
    for (id object in runtimeObjects) {
        if (WAGRFastExactReceiver(object, cls, selector)) {
            cache[cacheKey] = object;
            return object;
        }
    }

    id singleton = WAGRFastSingletonReceiver(cls, selector);
    if (singleton) {
        cache[cacheKey] = singleton;
        return singleton;
    }

    UIApplication *application = UIApplication.sharedApplication;
    id delegate = application.delegate;
    if (WAGRFastExactReceiver(delegate, cls, selector)) {
        cache[cacheKey] = delegate;
        return delegate;
    }
    for (UIWindow *window in application.windows) {
        if (WAGRFastExactReceiver(window, cls, selector)) {
            cache[cacheKey] = window;
            return window;
        }
        id found = WAGRFastFindInControllerTree(window.rootViewController, cls, selector);
        if (found) {
            cache[cacheKey] = found;
            return found;
        }
    }

    // Do not cache a miss forever. The exact instance can appear later, and an
    // installed RuntimeValueStore hook can capture it weakly during normal app use.
    return nil;
}

#pragma mark - Fast filtering

static BOOL WAGRFastStructuralSelector(NSString *selector) {
    if (!selector.length) return YES;
    NSString *lower = selector.lowercaseString;
    if ([lower hasPrefix:@"init"] || [lower hasPrefix:@"dealloc"] ||
        [lower hasPrefix:@"copy"] || [lower hasPrefix:@"mutablecopy"]) return YES;
    static NSSet<NSString *> *blocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = [NSSet setWithArray:@[
            @"hash", @"description", @"debugdescription", @"class", @"superclass",
            @"self", @"zone", @"retaincount", @"autorelease", @"retain", @"release",
            @"isproxy", @"isfault", @"observationinfo", @"methodsignatureforselector"
        ]];
    });
    return [blocked containsObject:lower];
}

static NSArray<NSString *> *WAGRFastTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [(query ?: @"").lowercaseString componentsSeparatedByCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

static NSString *WAGRFastHaystack(WAGREntry *entry) {
    NSString *cached = objc_getAssociatedObject(entry, kWAGRFastSurfaceHaystackKey);
    if (cached) return cached;
    cached = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@",
        entry.imageName ?: @"", entry.imagePath ?: @"", entry.runtimeFamily ?: @"",
        entry.runtimeSubcategory ?: @"", entry.className ?: @"", entry.selectorName ?: @"",
        entry.typeName ?: @"", entry.isClassMethod ? @"class" : @"instance"].lowercaseString;
    objc_setAssociatedObject(entry, kWAGRFastSurfaceHaystackKey, cached,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return cached;
}

static BOOL WAGRFastEntryScope(WAGREntry *entry, NSInteger scope) {
    switch (scope) {
        case 1: return WAGRRuntimeValueTypeIsBoolean(entry.typeCode);
        case 2: return WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
                       WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode) ||
                       WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode);
        case 3: return WAGRRuntimeValueTypeIsObject(entry.typeCode);
        case 4: return WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod);
        default: return YES;
    }
}

static NSString *WAGRFastSectionForEntry(id self, WAGREntry *entry) {
    SEL selector = NSSelectorFromString(@"sectionForEntry:");
    if ([self respondsToSelector:selector]) {
        @try {
            id value = ((id (*)(id, SEL, id))objc_msgSend)(self, selector, entry);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        } @catch (__unused NSException *exception) {}
    }
    return entry.runtimeFamily.length ? entry.runtimeFamily
        : (entry.className.length ? entry.className : @"Runtime");
}

static void WAGRFastScheduleSurfaceFilter(id self, NSTimeInterval delay) {
    UISearchController *search = WAGRFastKVC(self, @"search");
    if (!search) search = WAGRFastKVC(self, @"searchController");
    NSString *query = [search.searchBar.text copy] ?: @"";
    NSInteger scope = search.searchBar.selectedScopeButtonIndex;
    NSArray<WAGREntry *> *all = [WAGRFastKVC(self, @"allEntries") copy] ?: @[];

    uint64_t generation = [objc_getAssociatedObject(self, kWAGRFastSurfaceGenerationKey) unsignedLongLongValue] + 1;
    objc_setAssociatedObject(self, kWAGRFastSurfaceGenerationKey, @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([objc_getAssociatedObject(strongSelf, kWAGRFastSurfaceGenerationKey) unsignedLongLongValue] != generation) return;
        NSArray<NSString *> *tokens = WAGRFastTokens(query);
        NSMutableDictionary<NSString *, NSMutableArray<WAGREntry *> *> *groups = [NSMutableDictionary dictionary];
        NSUInteger filteredCount = 0, active = 0;
        for (WAGREntry *entry in all) {
            if (WAGRFastStructuralSelector(entry.selectorName)) continue;
            if (!WAGRFastEntryScope(entry, scope)) continue;
            NSString *haystack = WAGRFastHaystack(entry);
            BOOL matches = YES;
            for (NSString *token in tokens) {
                if (![haystack containsString:token]) { matches = NO; break; }
            }
            if (!matches) continue;
            NSString *section = WAGRFastSectionForEntry(strongSelf, entry);
            if (!groups[section]) groups[section] = [NSMutableArray array];
            [groups[section] addObject:entry];
            filteredCount++;
            if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod)) active++;
        }
        NSArray *keys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        dispatch_async(dispatch_get_main_queue(), ^{
            id target = weakSelf;
            if (!target) return;
            if ([objc_getAssociatedObject(target, kWAGRFastSurfaceGenerationKey) unsignedLongLongValue] != generation) return;
            WAGRFastSetKVC(target, @"sectionKeys", keys ?: @[]);
            WAGRFastSetKVC(target, @"sections", groups ?: @{});
            id spec = WAGRFastKVC(target, @"spec");
            NSString *baseTitle = WAGRFastKVC(spec, @"title") ?: @"Runtime";
            NSString *title = [NSString stringWithFormat:@"%@ (%lu)", baseTitle, (unsigned long)filteredCount];
            ((UIViewController *)target).title = active
                ? [title stringByAppendingFormat:@" · %lu ativos", (unsigned long)active] : title;
            [((UITableViewController *)target).tableView reloadData];
        });
    });
}

static void WAGRFastSurfaceApplyFilter(id self, SEL _cmd) {
    (void)_cmd;
    WAGRFastScheduleSurfaceFilter(self, 0.0);
}

static void WAGRFastSurfaceSearchUpdated(id self, SEL _cmd, UISearchController *searchController) {
    (void)_cmd; (void)searchController;
    WAGRFastScheduleSurfaceFilter(self, 0.11);
}

static void WAGRFastABSearchUpdated(id self, SEL _cmd, UISearchController *searchController) {
    (void)_cmd; (void)searchController;
    uint64_t generation = [objc_getAssociatedObject(self, kWAGRFastABGenerationKey) unsignedLongLongValue] + 1;
    objc_setAssociatedObject(self, kWAGRFastABGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.11 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id target = weakSelf;
        if (!target) return;
        if ([objc_getAssociatedObject(target, kWAGRFastABGenerationKey) unsignedLongLongValue] != generation) return;
        SEL apply = NSSelectorFromString(@"applyCurrentFilter");
        if ([target respondsToSelector:apply]) ((void (*)(id, SEL))objc_msgSend)(target, apply);
    });
}

#pragma mark - Typed inline runtime cells

static WAGREntry *WAGRFastSurfaceEntryAt(id self, NSIndexPath *path) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (![self respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(self, selector, path); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSString *WAGRFastCompactObject(id value) {
    if (!value) return @"nil";
    NSString *text = [value description] ?: @"?";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length > 72) text = [[text substringToIndex:72] stringByAppendingString:@"…"];
    return text;
}

static NSString *WAGRFastOriginalDisplay(WAGREntry *entry) {
    id raw = nil;
    NSString *text = WAGRRuntimeValueReadOriginal(entry.className, entry.selectorName,
                                                   entry.isClassMethod, nil, &raw);
    if ([text.lowercaseString containsString:@"indisponível"]) return @"aguardando receiver";
    if (raw) return WAGRFastCompactObject(raw);
    return text.length ? text : @"?";
}

static UITextField *WAGRFastField(id self, WAGREntry *entry, NSString *text) {
    BOOL floating = WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode);
    BOOL integer = WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
                   WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode);
    // Preserve room for long selector names. Complex objects use disclosure/full
    // editor; only simple strings get the wider inline field.
    CGFloat width = WAGRRuntimeValueTypeIsObject(entry.typeCode) ? 118.0 : 86.0;
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, width, 32.0)];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    field.textAlignment = NSTextAlignmentRight;
    field.adjustsFontSizeToFitWidth = YES;
    field.minimumFontSize = 8.5;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.returnKeyType = UIReturnKeyDone;
    field.keyboardType = floating ? UIKeyboardTypeDecimalPad
        : (integer ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeDefault);
    field.placeholder = floating ? @"decimal" : (integer ? @"inteiro" : @"texto");
    field.text = text ?: @"";
    objc_setAssociatedObject(field, kWAGRFastSurfaceEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [field addTarget:self action:NSSelectorFromString(@"wagr_fastSurfaceFieldCommit:")
      forControlEvents:UIControlEventEditingDidEnd];
    return field;
}

static UITableViewCell *WAGRFastSurfaceCell(id self, SEL _cmd, UITableView *table, NSIndexPath *path) {
    (void)_cmd;
    static NSString *reuse = @"WAGRFastTypedRuntimeCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGREntry *entry = WAGRFastSurfaceEntryAt(self, path);
    WAGRMenuApplyCellStyle(cell, path.row, entry.selectorName ?: @"runtime");
    cell.textLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.42;
    cell.textLabel.lineBreakMode = NSLineBreakByClipping;
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.58;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByClipping;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!entry) return cell;

    id raw = nil;
    SEL currentSelector = NSSelectorFromString(@"currentForEntry:raw:");
    NSString *current = [self respondsToSelector:currentSelector]
        ? ((id (*)(id, SEL, id, id *))objc_msgSend)(self, currentSelector, entry, &raw) : @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.isClassMethod);
    BOOL installed = overridden && WAGRRuntimeValueHookIsInstalled(entry.className,
                                                                    entry.selectorName,
                                                                    entry.isClassMethod);
    BOOL pending = overridden && !installed;
    id effective = overridden ? forced : raw;

    cell.textLabel.text = entry.selectorName ?: @"?";
    NSString *type = WAGRRuntimeValueTypeName(entry.typeCode) ?: entry.typeName ?: @"?";
    NSString *effectiveText = effective ? WAGRFastCompactObject(effective) : (current ?: @"?");
    if (overridden) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · orig %@ → eff %@ · %@",
            entry.className ?: @"Runtime", type, WAGRFastOriginalDisplay(entry),
            effectiveText, pending ? @"pending" : @"override"];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · original",
            entry.className ?: @"Runtime", type, effectiveText];
    }
    cell.detailTextLabel.textColor = pending ? UIColor.systemOrangeColor
        : (overridden ? UIColor.systemCyanColor : UIColor.secondaryLabelColor);

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [UISwitch new];
        toggle.on = effective && [effective respondsToSelector:@selector(boolValue)] ? [effective boolValue] : NO;
        toggle.onTintColor = pending ? UIColor.systemOrangeColor
            : (overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor);
        objc_setAssociatedObject(toggle, kWAGRFastSurfaceEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:NSSelectorFromString(@"wagr_fastSurfaceSwitchChanged:")
          forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
               WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode) ||
               WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode) ||
               (WAGRRuntimeValueTypeIsObject(entry.typeCode) &&
                (!effective || [effective isKindOfClass:NSString.class]))) {
        NSString *fieldText = effective ? [effective description] : @"";
        UITextField *field = WAGRFastField(self, entry, fieldText);
        field.textColor = pending ? UIColor.systemOrangeColor
            : (overridden ? UIColor.systemCyanColor : UIColor.labelColor);
        cell.accessoryView = field;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static BOOL WAGRFastInstallValue(WAGREntry *entry, id value) {
    if (!entry || !value) return NO;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.isClassMethod, entry.typeCode, value);
    return WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                       entry.isClassMethod, entry.typeCode);
}

static void WAGRFastSurfaceSwitch(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    WAGREntry *entry = objc_getAssociatedObject(sender, kWAGRFastSurfaceEntryKey);
    if (!entry) return;
    (void)WAGRFastInstallValue(entry, @(sender.isOn));
    WAGRFastReloadControlRow(self, sender);
}

static id WAGRFastParsedFieldValue(WAGREntry *entry, NSString *text, BOOL *valid) {
    if (valid) *valid = NO;
    if (!entry) return nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode)) {
        const char *start = trimmed.UTF8String ?: "";
        char *end = NULL;
        long long value = strtoll(start, &end, 0);
        if (end && *end == '\0' && end != start) { if (valid) *valid = YES; return @(value); }
    } else if (WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode)) {
        const char *start = trimmed.UTF8String ?: "";
        if (*start == '-') return nil;
        char *end = NULL;
        unsigned long long value = strtoull(start, &end, 0);
        if (end && *end == '\0' && end != start) { if (valid) *valid = YES; return @(value); }
    } else if (WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) {
        NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
        const char *start = normalized.UTF8String ?: "";
        char *end = NULL;
        double value = strtod(start, &end);
        if (end && *end == '\0' && end != start) { if (valid) *valid = YES; return @(value); }
    } else if (WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        if (valid) *valid = YES;
        return trimmed;
    }
    return nil;
}

static void WAGRFastSurfaceFieldCommit(id self, SEL _cmd, UITextField *field) {
    (void)_cmd;
    WAGREntry *entry = objc_getAssociatedObject(field, kWAGRFastSurfaceEntryKey);
    BOOL valid = NO;
    id value = WAGRFastParsedFieldValue(entry, field.text ?: @"", &valid);
    if (!valid || !value) {
        field.textColor = UIColor.systemRedColor;
        return;
    }
    (void)WAGRFastInstallValue(entry, value);
    WAGRFastReloadControlRow(self, field);
}

static void WAGRFastApplyAllSurfaceOverrides(id self, SEL _cmd) {
    (void)_cmd;
    NSArray<WAGREntry *> *all = WAGRFastKVC(self, @"allEntries") ?: @[];
    NSUInteger active = 0, installed = 0;
    for (WAGREntry *entry in all) {
        if (!WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod)) continue;
        active++;
        if (WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                        entry.isClassMethod, entry.typeCode)) installed++;
    }
    NSUInteger failed = active >= installed ? active - installed : 0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Aplicar Runtime"
        message:[NSString stringWithFormat:@"Overrides deste runtime: %lu\nInstalados/reaplicados: %lu\nPendentes: %lu",
                 (unsigned long)active, (unsigned long)installed, (unsigned long)failed]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
    WAGRFastScheduleSurfaceFilter(self, 0.0);
}

#pragma mark - Lightweight ABProps commits

static WAGRABPropEntry *WAGRFastABEntryForControl(id self, UIView *control) {
    UITableView *table = [self isKindOfClass:UITableViewController.class]
        ? ((UITableViewController *)self).tableView : nil;
    UITableViewCell *cell = WAGRFastOwningCell(control);
    NSIndexPath *path = (table && cell) ? [table indexPathForCell:cell] : nil;
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (!path || ![self respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(self, selector, path); }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRFastABSwitch(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    WAGRABPropEntry *entry = WAGRFastABEntryForControl(self, sender);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, @(sender.isOn));
    (void)WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                      entry.classMethod, entry.typeCode);
    WAGRFastReloadControlRow(self, sender);
}

static void WAGRFastABField(id self, SEL _cmd, UITextField *field) {
    (void)_cmd;
    WAGRABPropEntry *ab = WAGRFastABEntryForControl(self, field);
    if (!ab) return;
    WAGREntry *proxy = [WAGREntry new];
    proxy.className = ab.className;
    proxy.selectorName = ab.selectorName;
    proxy.typeCode = ab.typeCode;
    proxy.isClassMethod = ab.classMethod;
    BOOL valid = NO;
    id value = WAGRFastParsedFieldValue(proxy, field.text ?: @"", &valid);
    if (!valid || !value) { field.textColor = UIColor.systemRedColor; return; }
    WAGRRuntimeValueSetOverride(ab.className, ab.selectorName, ab.classMethod, ab.typeCode, value);
    (void)WAGRRuntimeValueInstallHook(ab.className, ab.selectorName, ab.classMethod, ab.typeCode);
    WAGRFastReloadControlRow(self, field);
}

#pragma mark - Installation

static void WAGRFastReplace(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method && method_getImplementation(method) != replacement) {
        method_setImplementation(method, replacement);
    }
}

static void WAGRFastAddOrReplace(Class cls, SEL selector, IMP replacement, const char *types) {
    if (!cls) return;
    if (!class_addMethod(cls, selector, replacement, types)) WAGRFastReplace(cls, selector, replacement);
}

static void WAGRFastInstall(void) {
    Class surface = NSClassFromString(@"WAGRSurfaceBrowserVC");
    if (surface) {
        WAGRFastReplace(surface, NSSelectorFromString(@"applyCurrentFilter"), (IMP)WAGRFastSurfaceApplyFilter);
        WAGRFastReplace(surface, @selector(updateSearchResultsForSearchController:), (IMP)WAGRFastSurfaceSearchUpdated);
        WAGRFastReplace(surface, NSSelectorFromString(@"receiverForEntry:"), (IMP)WAGRFastSurfaceReceiver);
        WAGRFastReplace(surface, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRFastSurfaceCell);
        WAGRFastReplace(surface, NSSelectorFromString(@"applyVisibleOverrides"), (IMP)WAGRFastApplyAllSurfaceOverrides);
        WAGRFastAddOrReplace(surface, NSSelectorFromString(@"wagr_fastSurfaceSwitchChanged:"),
                             (IMP)WAGRFastSurfaceSwitch, "v@:@");
        WAGRFastAddOrReplace(surface, NSSelectorFromString(@"wagr_fastSurfaceFieldCommit:"),
                             (IMP)WAGRFastSurfaceFieldCommit, "v@:@");
    }

    Class ab = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (ab) {
        WAGRFastReplace(ab, @selector(updateSearchResultsForSearchController:), (IMP)WAGRFastABSearchUpdated);
        // WAGRABPropsInlineTypedUI owns the ABI-aware cell renderer. Only its
        // commit actions are replaced here; the final glass pass post-processes
        // typography/stable-ID presentation without removing those controls.
        WAGRFastReplace(ab, NSSelectorFromString(@"wagr_inlineABSwitchChanged:"), (IMP)WAGRFastABSwitch);
        WAGRFastReplace(ab, NSSelectorFromString(@"wagr_inlineABFieldCommit:"), (IMP)WAGRFastABField);
    }
}

__attribute__((constructor))
static void WAGRRuntimeBrowserFastTypedUICtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRFastInstall(); });
        });
    }
}
