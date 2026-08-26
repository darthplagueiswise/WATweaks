#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRLog.h"

// Final compact/performance pass for WAGRABPropsBrowserVC.
//
// Why this exists instead of another debounce:
// - the old search rebuilt a fairly large haystack for every WAAB getter on the
//   MAIN THREAD for every keystroke;
// - native[@"value"] can itself be a huge JSON string (wamo_abprops_list is the
//   obvious example), so one character could repeatedly lowercase/copy megabytes;
// - WAGRABPropsInlineTypedUI is intentionally the final semantic cell renderer,
//   therefore the visual pass must run after it and only post-process its cell.
//
// Search now does zero artificial waiting: each keystroke snapshots immutable
// input, filters on a dedicated user-initiated queue, and only the newest
// generation is committed on main. Search haystacks/family names are cached on
// each WAGRABPropEntry for the life of that scan.

static const void *kWAGRABFastHaystackKey = &kWAGRABFastHaystackKey;
static const void *kWAGRABFastFamilyKey = &kWAGRABFastFamilyKey;
static const void *kWAGRABFastGenerationKey = &kWAGRABFastGenerationKey;

static UITableViewCell *(*orig_WAGRABFastCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*orig_WAGRABFastViewDidLoad)(id, SEL) = NULL;
static BOOL gWAGRABFastInstalled = NO;

static dispatch_queue_t WAGRABFastSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.watweaks.abprops.search", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

static id WAGRABFastKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRABFastSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static NSArray<NSString *> *WAGRABFastTokens(NSString *query) {
    NSString *lower = query.lowercaseString ?: @"";
    if (!lower.length) return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:3];
    for (NSString *piece in [lower componentsSeparatedByCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (piece.length) [tokens addObject:piece];
    }
    return tokens;
}

static NSString *WAGRABFastBoundedValue(id value) {
    if (!value || value == NSNull.null) return @"";
    NSString *text = [value isKindOfClass:NSString.class] ? value : [value description];
    if (!text.length) return @"";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    // Search identifiers and small scalar values, never copy/lowercase a complete
    // embedded JSON payload on each query.
    if (text.length > 128) text = [text substringToIndex:128];
    return text;
}

static NSString *WAGRABFastFamily(WAGRABPropEntry *entry) {
    NSString *cached = objc_getAssociatedObject(entry, kWAGRABFastFamilyKey);
    if (cached) return cached;
    NSString *family = WAGRLiveRuntimeFamilyForSelector(entry.selectorName,
                                                         entry.className);
    if (!family.length) family = @"Other Runtime";
    objc_setAssociatedObject(entry, kWAGRABFastFamilyKey, family,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return family;
}

static NSString *WAGRABFastHaystack(WAGRABPropEntry *entry,
                                     NSDictionary *nativeIndex) {
    NSString *cached = objc_getAssociatedObject(entry, kWAGRABFastHaystackKey);
    if (cached) return cached;

    NSDictionary *native = entry.selectorName.length &&
        [nativeIndex[entry.selectorName] isKindOfClass:NSDictionary.class]
        ? nativeIndex[entry.selectorName] : @{};
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? native[@"mobileconfig"] : @{};

    NSString *stable = [native[@"code"] description];
    if (!stable.length) {
        stable = WAGRABPropsStableIDForTarget(entry.className,
                                              entry.selectorName,
                                              entry.classMethod);
    }

    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@ %@ %@",
        WAGRABFastFamily(entry),
        entry.categoryName ?: @"",
        entry.selectorName ?: @"",
        entry.className ?: @"",
        entry.typeName ?: @"",
        entry.sourceImage ?: @"",
        stable ?: @"",
        WAGRABFastBoundedValue(native[@"value"]),
        [mc[@"parameter_name"] isKindOfClass:NSString.class] ? mc[@"parameter_name"] : @"",
        [mc[@"config_name"] isKindOfClass:NSString.class] ? mc[@"config_name"] : @""].lowercaseString;

    objc_setAssociatedObject(entry, kWAGRABFastHaystackKey, haystack,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return haystack;
}

static BOOL WAGRABFastMatchesScope(WAGRABPropEntry *entry, NSInteger scope) {
    switch (scope) {
        case 0: return YES;
        case 1: return WAGRRuntimeValueTypeIsBoolean(entry.typeCode);
        case 2: return WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
                       WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode) ||
                       WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode);
        case 3: return WAGRRuntimeValueTypeIsObject(entry.typeCode);
        case 4: return WAGRRuntimeValueHasOverride(entry.className,
                                                   entry.selectorName,
                                                   entry.classMethod);
        default: return YES;
    }
}

static void WAGRABFastApplyCurrentFilter(id self, __unused SEL _cmd) {
    UISearchController *searchController = WAGRABFastKVC(self, @"searchController");
    UISearchBar *searchBar = searchController.searchBar;
    NSString *query = [searchBar.text copy] ?: @"";
    NSInteger scope = searchBar.selectedScopeButtonIndex;
    NSArray<WAGRABPropEntry *> *entries = [WAGRABFastKVC(self, @"allEntries") copy] ?: @[];
    NSDictionary *nativeIndex = [WAGRABFastKVC(self, @"nativeEntriesBySelector") copy] ?: @{};
    NSArray<NSString *> *tokens = WAGRABFastTokens(query);

    NSUInteger generation = [objc_getAssociatedObject(self, kWAGRABFastGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self, kWAGRABFastGenerationKey, @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakSelf = self;

    dispatch_async(WAGRABFastSearchQueue(), ^{
        NSMutableArray<WAGRABPropEntry *> *filtered = [NSMutableArray arrayWithCapacity:entries.count];
        for (WAGRABPropEntry *entry in entries) {
            if (!WAGRABFastMatchesScope(entry, scope)) continue;
            NSString *haystack = WAGRABFastHaystack(entry, nativeIndex);
            BOOL matches = YES;
            for (NSString *token in tokens) {
                if ([haystack rangeOfString:token].location == NSNotFound) {
                    matches = NO;
                    break;
                }
            }
            if (matches) [filtered addObject:entry];
        }

        NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups =
            [NSMutableDictionary dictionary];
        for (WAGRABPropEntry *entry in filtered) {
            NSString *family = WAGRABFastFamily(entry);
            NSMutableArray *rows = groups[family];
            if (!rows) {
                rows = [NSMutableArray array];
                groups[family] = rows;
            }
            [rows addObject:entry];
        }
        NSArray<NSString *> *keys = [groups.allKeys sortedArrayUsingSelector:
                                     @selector(localizedCaseInsensitiveCompare:)];
        NSDictionary *immutableGroups = [groups copy];

        dispatch_async(dispatch_get_main_queue(), ^{
            id strongSelf = weakSelf;
            if (!strongSelf) return;
            NSUInteger latest = [objc_getAssociatedObject(strongSelf,
                                                            kWAGRABFastGenerationKey)
                                 unsignedIntegerValue];
            if (latest != generation) return; // stale query; never flash old results

            WAGRABFastSetKVC(strongSelf, @"sectionKeys", keys ?: @[]);
            WAGRABFastSetKVC(strongSelf, @"sections", immutableGroups ?: @{});
            if ([strongSelf isKindOfClass:UIViewController.class]) {
                ((UIViewController *)strongSelf).title =
                    [NSString stringWithFormat:@"WAAB (%lu)",
                     (unsigned long)filtered.count];
            }
            UITableView *table = WAGRABFastKVC(strongSelf, @"tableView");
            [table reloadData];
        });
    });
}

static void WAGRABFastViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRABFastViewDidLoad) orig_WAGRABFastViewDidLoad(self, _cmd);
    UITableView *table = WAGRABFastKVC(self, @"tableView");
    table.rowHeight = 50.0;
    table.estimatedRowHeight = 50.0;
}

static UITableViewCell *WAGRABFastCell(id self, SEL _cmd,
                                       UITableView *table,
                                       NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_WAGRABFastCell
        ? orig_WAGRABFastCell(self, _cmd, table, indexPath) : nil;
    if (!cell) return cell;

    WAGRABPropEntry *entry = nil;
    SEL entrySelector = NSSelectorFromString(@"entryAtIndexPath:");
    if ([self respondsToSelector:entrySelector]) {
        @try { entry = ((id (*)(id, SEL, id))objc_msgSend)(self, entrySelector, indexPath); }
        @catch (__unused NSException *exception) { entry = nil; }
    }

    // The inline typed renderer used 15/11.5 pt and allowed two title lines. That
    // was the reason the internal ABProps browser still looked much larger than
    // the generic Runtime Browser even after the shared theme was reduced.
    cell.textLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.50;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    cell.detailTextLabel.font = [UIFont systemFontOfSize:8.75 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.65;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    if ([cell.accessoryView isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)cell.accessoryView;
        field.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
        field.minimumFontSize = 8.0;
        CGRect frame = field.frame;
        frame.size.width = MIN(frame.size.width, 104.0);
        frame.size.height = 30.0;
        field.frame = frame;
    }

    // Guarantee the AB stable ID in the small subtitle even when the native
    // gabp snapshot has not yet correlated this selector. Descriptor-backed
    // getters can still resolve their current-build ID directly from ARM64.
    if (entry) {
        NSString *detail = cell.detailTextLabel.text ?: @"";
        if ([detail rangeOfString:@"AB "].location == NSNotFound &&
            [detail rangeOfString:@"AB #"].location == NSNotFound) {
            NSString *stable = WAGRABPropsStableIDForTarget(entry.className,
                                                            entry.selectorName,
                                                            entry.classMethod);
            if (stable.length) {
                cell.detailTextLabel.text = detail.length
                    ? [NSString stringWithFormat:@"AB %@ · %@", stable, detail]
                    : [NSString stringWithFormat:@"AB %@", stable];
            }
        }
    }
    return cell;
}

static void WAGRABFastInstall(void) {
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (!cls) return;

    // Replace applyCurrentFilter itself: typing, scope changes, scan completion,
    // override changes and editor callbacks all use the same non-blocking path.
    SEL filterSelector = NSSelectorFromString(@"applyCurrentFilter");
    Method filterMethod = class_getInstanceMethod(cls, filterSelector);
    if (filterMethod && method_getImplementation(filterMethod) != (IMP)WAGRABFastApplyCurrentFilter) {
        method_setImplementation(filterMethod, (IMP)WAGRABFastApplyCurrentFilter);
    }

    SEL loadSelector = @selector(viewDidLoad);
    Method loadMethod = class_getInstanceMethod(cls, loadSelector);
    IMP loadCurrent = loadMethod ? method_getImplementation(loadMethod) : NULL;
    if (loadMethod && loadCurrent != (IMP)WAGRABFastViewDidLoad) {
        orig_WAGRABFastViewDidLoad = (void (*)(id, SEL))loadCurrent;
        method_setImplementation(loadMethod, (IMP)WAGRABFastViewDidLoad);
    }

    SEL cellSelector = @selector(tableView:cellForRowAtIndexPath:);
    Method cellMethod = class_getInstanceMethod(cls, cellSelector);
    IMP cellCurrent = cellMethod ? method_getImplementation(cellMethod) : NULL;
    if (cellMethod && cellCurrent != (IMP)WAGRABFastCell) {
        orig_WAGRABFastCell = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))cellCurrent;
        method_setImplementation(cellMethod, (IMP)WAGRABFastCell);
    }

    if (!gWAGRABFastInstalled) {
        gWAGRABFastInstalled = YES;
        WAGRLogAppend(@"[ABProps][UI] compact rows + zero-delay off-main search installed");
    }
}

__attribute__((constructor))
static void WAGRABPropsBrowserPerformanceUICtor(void) {
    @autoreleasepool {
        // InlineTypedUI deliberately retries at +0.35 s. Install after it so this
        // post-processing wrapper remains the outermost renderer.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.70 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRABFastInstall(); });
    }
}
