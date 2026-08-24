#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"
#import "../Runtime/WAGRABPropsNativeStore.h"

static void (*orig_WAGRMCExportViewDidLoad)(id, SEL) = NULL;
static void (*orig_WAGRMCExportApplyFilter)(id, SEL) = NULL;
static void (*orig_WAGRMCExportSetStatus)(id, SEL, NSString *, float) = NULL;
static void (*orig_WAGRMCExportShowMenu)(id, SEL, UIBarButtonItem *) = NULL;

static id WAGRMCUIKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRMCUISetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static NSSet<NSNumber *> *WAGRMCUIAccountCodes(WAGRABPropsNativeSnapshot **outSnapshot) {
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(NULL);
    if (outSnapshot) *outSnapshot = snapshot;
    if (!snapshot.props.count) return [NSSet set];
    NSMutableSet<NSNumber *> *codes = [NSMutableSet setWithCapacity:snapshot.numericPropCount];
    for (id key in snapshot.props) {
        unsigned long long value = [[key description] longLongValue];
        if (value) [codes addObject:@(value)];
    }
    return codes;
}

static void WAGRMCUIEnrichMapping(WAGRMobileConfigMapping *mapping, id userContext) {
    if (!mapping || !mapping.paramSpecifier) return;
    if (!mapping.externalConfigStableId) {
        uint64_t stable = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext, mapping.paramSpecifier);
        if (stable) mapping.externalConfigStableId = stable;
    }
    if (!mapping.configName.length || !mapping.parameterName.length) {
        NSString *full = WAGRMobileConfigRuntimeNameForSpecifier(mapping.paramSpecifier);
        NSString *config = nil, *parameter = nil;
        WAGRMobileConfigRuntimeSplitName(full, &config, &parameter);
        if (!mapping.configName.length && config.length) mapping.configName = config;
        if (!mapping.parameterName.length && parameter.length) mapping.parameterName = parameter;
    }
}

static UIFont *WAGRMCUITitleFont(void) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    return [UIFont systemFontOfSize:MAX(16.0, font.pointSize) weight:UIFontWeightRegular];
}

static UIFont *WAGRMCUIDetailFont(void) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    return [UIFont systemFontOfSize:MAX(13.0, font.pointSize) weight:UIFontWeightRegular];
}

static NSString *WAGRMCUINoHeader(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return nil;
}

static CGFloat WAGRMCUIHeaderHeight(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return 12.0;
}

static CGFloat WAGRMCUIFooterHeight(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section;
    return 5.0;
}

static void WAGRMCUIApplyFilter(id self, SEL _cmd) {
    if (orig_WAGRMCExportApplyFilter) orig_WAGRMCExportApplyFilter(self, _cmd);

    UISearchController *search = WAGRMCUIKVC(self, @"searchController");
    NSInteger scope = search.searchBar.selectedScopeButtonIndex;
    NSArray<WAGRMobileConfigMapping *> *visible = WAGRMCUIKVC(self, @"visibleMappings") ?: @[];
    WAGRABPropsNativeSnapshot *snapshot = nil;
    NSSet<NSNumber *> *accountCodes = WAGRMCUIAccountCodes(&snapshot);

    if (scope == 0 && accountCodes.count) {
        NSMutableArray<WAGRMobileConfigMapping *> *account = [NSMutableArray array];
        for (WAGRMobileConfigMapping *mapping in visible) {
            if ([accountCodes containsObject:@(mapping.waStableId)]) [account addObject:mapping];
        }
        visible = account;
        WAGRMCUISetKVC(self, @"visibleMappings", visible);
    }

    search.searchBar.placeholder = snapshot.numericPropCount
        ? [NSString stringWithFormat:@"Buscar · %lu ABProps na conta", (unsigned long)snapshot.numericPropCount]
        : @"Buscar WA ID, config ou parâmetro";
    ((UIViewController *)self).title = scope == 0 ? @"AB → MC · Conta" : @"AB → MC · Domínio";
    [((UITableViewController *)self).tableView reloadData];
}

static void WAGRMCUIScopeChanged(id self, SEL _cmd, UISearchBar *searchBar, NSInteger index) {
    (void)_cmd; (void)searchBar; (void)index;
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"applyFilter"));
}

static void WAGRMCUIViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRMCExportViewDidLoad) orig_WAGRMCExportViewDidLoad(self, _cmd);
    UITableViewController *controller = (UITableViewController *)self;
    controller.tableView.estimatedRowHeight = 62.0;
    controller.tableView.rowHeight = UITableViewAutomaticDimension;
    controller.tableView.sectionHeaderHeight = 12.0;
    controller.tableView.sectionFooterHeight = 5.0;
    if (@available(iOS 15.0, *)) controller.tableView.sectionHeaderTopPadding = 0.0;

    UISearchController *search = WAGRMCUIKVC(self, @"searchController");
    search.searchBar.scopeButtonTitles = @[ @"Conta", @"Domínio" ];
    search.searchBar.selectedScopeButtonIndex = 0;
    search.searchBar.delegate = self;
    controller.navigationItem.hidesSearchBarWhenScrolling = YES;
    if (@available(iOS 16.0, *)) {
        controller.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }
    controller.title = @"AB → MC · Conta";
}

static void WAGRMCUISetStatus(id self, SEL _cmd, NSString *status, float progress) {
    NSString *replacement = status;
    if (progress >= 0.999f) {
        UISearchController *search = WAGRMCUIKVC(self, @"searchController");
        NSInteger scope = search.searchBar.selectedScopeButtonIndex;
        NSArray *visible = WAGRMCUIKVC(self, @"visibleMappings") ?: @[];
        NSArray *all = WAGRMCUIKVC(self, @"allMappings") ?: @[];
        WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(NULL);
        if (scope == 0 && snapshot.numericPropCount) {
            replacement = [NSString stringWithFormat:@"%lu no cache · %lu traduzidos · nomes resolvidos pelo schema runtime",
                (unsigned long)snapshot.numericPropCount, (unsigned long)visible.count];
        } else if (snapshot.numericPropCount) {
            replacement = [NSString stringWithFormat:@"%lu traduzidos no domínio · %lu ABProps na conta",
                (unsigned long)all.count, (unsigned long)snapshot.numericPropCount];
        }
    }
    if (orig_WAGRMCExportSetStatus) orig_WAGRMCExportSetStatus(self, _cmd, replacement, progress);
}

static UITableViewCell *WAGRMCUICell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    NSArray<WAGRMobileConfigMapping *> *visible = WAGRMCUIKVC(self, @"visibleMappings") ?: @[];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)visible.count) return [UITableViewCell new];
    WAGRMobileConfigMapping *mapping = visible[(NSUInteger)indexPath.row];
    id userContext = WAGRMCUIKVC(self, @"userContext");
    WAGRMCUIEnrichMapping(mapping, userContext);

    static NSString *reuse = @"WAGRMCNativeSettingsCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGRMenuApplyCellStyle(cell, indexPath.row, mapping.parameterName ?: mapping.configName ?: @"mobileconfig");
    cell.textLabel.font = WAGRMCUITitleFont();
    cell.detailTextLabel.font = WAGRMCUIDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    NSString *title = nil;
    if (mapping.parameterName.length) title = mapping.parameterName;
    else if (mapping.configName.length) title = mapping.configName;
    else title = [NSString stringWithFormat:@"WA %lu", (unsigned long)mapping.waStableId];
    cell.textLabel.text = title;

    NSMutableString *detail = [NSMutableString stringWithFormat:@"WA %lu · p%u",
        (unsigned long)mapping.waStableId, mapping.parameterIndex];
    if (mapping.externalConfigStableId) {
        [detail appendFormat:@" · config %llu", mapping.externalConfigStableId];
    }
    if (mapping.configName.length && mapping.parameterName.length) {
        [detail appendFormat:@"\n%@", mapping.configName];
    }
    cell.detailTextLabel.text = detail;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

static void WAGRMCUIShowExportMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    NSArray<WAGRMobileConfigMapping *> *mappings = WAGRMCUIKVC(self, @"allMappings") ?: @[];
    id userContext = WAGRMCUIKVC(self, @"userContext");
    if (!mappings.count || !orig_WAGRMCExportShowMenu) {
        if (orig_WAGRMCExportShowMenu) orig_WAGRMCExportShowMenu(self, _cmd, sender);
        return;
    }

    NSString *oldTitle = ((UIViewController *)self).title;
    ((UIViewController *)self).title = @"Resolvendo schema…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (WAGRMobileConfigMapping *mapping in mappings) {
            @autoreleasepool { WAGRMCUIEnrichMapping(mapping, userContext); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ((UIViewController *)self).title = oldTitle ?: @"AB → MC";
            orig_WAGRMCExportShowMenu(self, _cmd, sender);
        });
    });
}

static IMP WAGRMCUIReplaceAndCapture(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    if (original != replacement) method_setImplementation(method, replacement);
    return original;
}

static void WAGRMCUIReplace(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method && method_getImplementation(method) != replacement) method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void WAGRMobileConfigExportRuntimeUICtor(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
        if (!cls) return;
        orig_WAGRMCExportViewDidLoad = (void (*)(id, SEL))WAGRMCUIReplaceAndCapture(cls, @selector(viewDidLoad), (IMP)WAGRMCUIViewDidLoad);
        orig_WAGRMCExportApplyFilter = (void (*)(id, SEL))WAGRMCUIReplaceAndCapture(cls, NSSelectorFromString(@"applyFilter"), (IMP)WAGRMCUIApplyFilter);
        orig_WAGRMCExportSetStatus = (void (*)(id, SEL, NSString *, float))WAGRMCUIReplaceAndCapture(cls, NSSelectorFromString(@"setStatus:progress:"), (IMP)WAGRMCUISetStatus);
        orig_WAGRMCExportShowMenu = (void (*)(id, SEL, UIBarButtonItem *))WAGRMCUIReplaceAndCapture(cls, NSSelectorFromString(@"showExportMenu:"), (IMP)WAGRMCUIShowExportMenu);
        WAGRMCUIReplace(cls, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRMCUICell);
        WAGRMCUIReplace(cls, @selector(tableView:titleForHeaderInSection:), (IMP)WAGRMCUINoHeader);
        WAGRMCUIReplace(cls, @selector(tableView:titleForFooterInSection:), (IMP)WAGRMCUINoHeader);
        if (!class_addMethod(cls, @selector(tableView:heightForHeaderInSection:), (IMP)WAGRMCUIHeaderHeight, "d@:@q")) {
            WAGRMCUIReplace(cls, @selector(tableView:heightForHeaderInSection:), (IMP)WAGRMCUIHeaderHeight);
        }
        if (!class_addMethod(cls, @selector(tableView:heightForFooterInSection:), (IMP)WAGRMCUIFooterHeight, "d@:@q")) {
            WAGRMCUIReplace(cls, @selector(tableView:heightForFooterInSection:), (IMP)WAGRMCUIFooterHeight);
        }
        class_addMethod(cls, @selector(searchBar:selectedScopeButtonIndexDidChange:), (IMP)WAGRMCUIScopeChanged, "v@:@q");
    }
}
