#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsCodeResolver.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

static id WAGRUnifiedFilterKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRUnifiedFilterSetKVC(id object, NSString *key, id value) {
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static NSArray<NSString *> *WAGRUnifiedFilterTokens(NSString *query) {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *part in [(query ?: @"").lowercaseString
                             componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

static NSInteger WAGRUnifiedFilterRank(WAGRABPropEntry *entry) {
    NSString *name = entry.className ?: @"";
    if ([name isEqualToString:@"WAABProperties"]) return 0;
    if ([name containsString:@"WAABProperties"]) return 1;
    if ([name containsString:@"FOAWAABProperties"]) return 2;
    return 3;
}

static void WAGRUnifiedABApplyFilter(id self, SEL _cmd) {
    (void)_cmd;
    UISearchController *search = WAGRUnifiedFilterKVC(self, @"searchController");
    NSArray<WAGRABPropEntry *> *allEntries = WAGRUnifiedFilterKVC(self, @"allEntries") ?: @[];
    NSDictionary *nativeIndex = WAGRUnifiedFilterKVC(self, @"nativeEntriesBySelector") ?: @{};
    NSInteger scope = search.searchBar.selectedScopeButtonIndex;
    NSArray<NSString *> *tokens = WAGRUnifiedFilterTokens(search.searchBar.text);

    NSMutableDictionary<NSString *, WAGRABPropEntry *> *bestBySelector = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in allEntries) {
        if (!entry.selectorName.length) continue;
        NSDictionary *native = [nativeIndex[entry.selectorName] isKindOfClass:NSDictionary.class]
            ? nativeIndex[entry.selectorName] : nil;
        BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
        if (scope == 0 && !native) continue;       // Conta = allocated cache only.
        if (scope == 2 && !overridden) continue;  // Overrides = same RuntimeValueStore.

        NSString *descriptorCode = WAGRABPropsCodeForEntry(entry) ?: @"";
        NSString *snapshotCode = [native[@"code"] description] ?: @"";
        NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? native[@"mobileconfig"] : @{};
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@ %@ %@",
            descriptorCode, snapshotCode,
            entry.selectorName ?: @"", entry.className ?: @"", entry.categoryName ?: @"",
            native[@"name"] ?: @"", native[@"value"] ?: @"",
            mc[@"config_name"] ?: @"", mc[@"parameter_name"] ?: @"",
            mc[@"external_config_stable_id"] ?: @""].lowercaseString;
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (![haystack containsString:token]) { matches = NO; break; }
        }
        if (!matches) continue;

        WAGRABPropEntry *existing = bestBySelector[entry.selectorName];
        if (!existing || WAGRUnifiedFilterRank(entry) < WAGRUnifiedFilterRank(existing)) {
            bestBySelector[entry.selectorName] = entry;
        }
    }

    NSArray<WAGRABPropEntry *> *filtered = [bestBySelector.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(WAGRABPropEntry *left, WAGRABPropEntry *right) {
            if (scope == 1) {
                NSString *lf = WAGRLiveRuntimeFamilyForSelector(left.selectorName, left.className) ?: @"Runtime";
                NSString *rf = WAGRLiveRuntimeFamilyForSelector(right.selectorName, right.className) ?: @"Runtime";
                NSComparisonResult family = [lf localizedCaseInsensitiveCompare:rf];
                if (family != NSOrderedSame) return family;
            }
            return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
        }];

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups = [NSMutableDictionary dictionary];
    NSArray<NSString *> *keys = nil;
    if (scope == 1) {
        for (WAGRABPropEntry *entry in filtered) {
            NSString *family = WAGRLiveRuntimeFamilyForSelector(entry.selectorName, entry.className);
            if (!family.length) family = @"Runtime";
            if (!groups[family]) groups[family] = [NSMutableArray array];
            [groups[family] addObject:entry];
        }
        keys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    } else {
        NSString *key = scope == 2 ? @"Overrides" : @"Conta";
        groups[key] = [filtered mutableCopy] ?: [NSMutableArray array];
        keys = @[key];
    }
    WAGRUnifiedFilterSetKVC(self, @"sectionKeys", keys ?: @[]);
    WAGRUnifiedFilterSetKVC(self, @"sections", groups ?: @{});

    WAGRABPropsNativeSnapshot *snapshot = WAGRUnifiedFilterKVC(self, @"nativeSnapshot");
    NSUInteger cacheCount = snapshot.numericPropCount;
    search.searchBar.placeholder = cacheCount
        ? [NSString stringWithFormat:@"Buscar nome ou AB ID em %lu", (unsigned long)cacheCount]
        : @"Buscar nome ou AB ID";
    ((UIViewController *)self).title = scope == 0 ? @"WAAB · Conta"
        : (scope == 1 ? @"WAAB · Runtime" : @"WAAB · Overrides");
    [((UITableViewController *)self).tableView reloadData];
}

static void WAGRUnifiedFilterInstall(void) {
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"applyCurrentFilter")) : NULL;
    if (method && method_getImplementation(method) != (IMP)WAGRUnifiedABApplyFilter) {
        method_setImplementation(method, (IMP)WAGRUnifiedABApplyFilter);
    }
}

__attribute__((constructor))
static void WAGRUnifiedFilterCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // CompactUI replaces applyCurrentFilter in its constructor; install
            // afterwards so exact getter-descriptor IDs participate in Runtime
            // search even when that ABProp is not allocated in gabp.*p.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.70 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRUnifiedFilterInstall(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRUnifiedFilterInstall(); });
        });
    }
}
