#import "WAGRABPropsBrowserVC.h"
#import "WAGRMenuTheme.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, WAGRABBrowserScope) {
    WAGRABBrowserScopeFeatured = 0,
    WAGRABBrowserScopeAll,
    WAGRABBrowserScopeBoolean,
    WAGRABBrowserScopeNumeric,
    WAGRABBrowserScopeObject,
    WAGRABBrowserScopeOverrides,
};

static const void *kWAGRABSwitchEntryKey = &kWAGRABSwitchEntryKey;
static const void *kWAGRABLongPressKey = &kWAGRABLongPressKey;

@interface WAGRABPropsBrowserVC ()
@property(nonatomic, strong) id userContext;
@property(nonatomic, strong) NSArray *runtimeObjects;
@property(nonatomic, strong) NSArray<WAGRABPropEntry *> *allEntries;
@property(nonatomic, strong) NSArray<NSString *> *sectionKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<WAGRABPropEntry *> *> *sections;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, assign) BOOL didScan;
@end

@implementation WAGRABPropsBrowserVC

- (instancetype)initWithUserContext:(id)userContext {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _userContext = userContext;
    _runtimeObjects = @[];
    _allEntries = @[];
    _sectionKeys = @[];
    _sections = @{};
    self.title = @"AB Props";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 72.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.placeholder = @"Buscar nome, categoria, classe ou tipo";
    search.searchBar.scopeButtonTitles = @[
        @"Destaques", @"Todos", @"BOOL", @"Números", @"Objetos", @"Overrides"
    ];
    search.searchBar.selectedScopeButtonIndex = WAGRABBrowserScopeFeatured;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.searchController = search;

    UIBarButtonItem *scan = [[UIBarButtonItem alloc] initWithTitle:@"Scan"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(scanNow)];
    UIBarButtonItem *overrides = [[UIBarButtonItem alloc] initWithTitle:@"Ativos"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(showActiveOverrides)];
    self.navigationItem.rightBarButtonItems = @[scan, overrides];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didScan) [self scanNow];
}

- (void)scanNow {
    self.didScan = YES;
    self.title = @"Escaneando AB Props…";
    id context = self.userContext;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = WAGRABPropsResolveRuntimeObjects(context);
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runtimeObjects = objects ?: @[];
            self.allEntries = entries ?: @[];
            [self applyCurrentFilter];
        });
    });
}

static NSArray<NSString *> *WAGRABSearchTokens(NSString *query) {
    NSArray *parts = [[query lowercaseString] componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *part in parts) if (part.length) [tokens addObject:part];
    return tokens;
}

static BOOL WAGRABEntryIsFeatured(WAGRABPropEntry *entry) {
    if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) return YES;
    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
        entry.categoryName ?: @"", entry.selectorName ?: @"", entry.className ?: @""].lowercaseString;
    for (NSString *token in @[
        @"employee", @"internal", @"dogfood", @"debug", @"developer",
        @"private", @"experiment", @"sandbox", @"mobileconfig", @"rage",
        @"testuser", @"test_user", @"whatsbroken"
    ]) {
        if ([haystack containsString:token]) return YES;
    }
    return NO;
}

static BOOL WAGRABEntryMatchesScope(WAGRABPropEntry *entry,
                                    WAGRABBrowserScope scope,
                                    BOOL hasSearchText) {
    switch (scope) {
        case WAGRABBrowserScopeFeatured:
            return hasSearchText ? YES : WAGRABEntryIsFeatured(entry);
        case WAGRABBrowserScopeAll:
            return YES;
        case WAGRABBrowserScopeBoolean:
            return WAGRRuntimeValueTypeIsBoolean(entry.typeCode);
        case WAGRABBrowserScopeNumeric:
            return WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
                   WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode) ||
                   WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode);
        case WAGRABBrowserScopeObject:
            return WAGRRuntimeValueTypeIsObject(entry.typeCode);
        case WAGRABBrowserScopeOverrides:
            return WAGRRuntimeValueHasOverride(entry.className,
                                               entry.selectorName,
                                               entry.classMethod);
    }
    return YES;
}

- (void)applyCurrentFilter {
    NSString *query = self.searchController.searchBar.text ?: @"";
    NSArray<NSString *> *tokens = WAGRABSearchTokens(query);
    WAGRABBrowserScope scope = (WAGRABBrowserScope)self.searchController.searchBar.selectedScopeButtonIndex;

    NSMutableArray<WAGRABPropEntry *> *filtered = [NSMutableArray array];
    for (WAGRABPropEntry *entry in self.allEntries) {
        if (!WAGRABEntryMatchesScope(entry, scope, tokens.count > 0)) continue;
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
            entry.categoryName ?: @"", entry.selectorName ?: @"",
            entry.className ?: @"", entry.typeName ?: @"",
            entry.sourceImage ?: @"", entry.classMethod ? @"class" : @"instance"].lowercaseString;
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (![haystack containsString:token]) { matches = NO; break; }
        }
        if (matches) [filtered addObject:entry];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups =
        [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in filtered) {
        NSString *category = entry.categoryName.length ? entry.categoryName : entry.className;
        if (!category.length) category = @"Other";
        if (!groups[category]) groups[category] = [NSMutableArray array];
        [groups[category] addObject:entry];
    }
    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:
        @selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups;

    NSUInteger active = 0;
    for (WAGRABPropEntry *entry in filtered) {
        if (WAGRRuntimeValueHasOverride(entry.className,
                                        entry.selectorName,
                                        entry.classMethod)) active++;
    }
    NSDictionary *stats = WAGRABPropsCatalogStats();
    NSUInteger supported = [stats[@"selectors_supported"] unsignedIntegerValue];
    NSString *base = supported
        ? [NSString stringWithFormat:@"AB Props %lu/%lu",
             (unsigned long)filtered.count, (unsigned long)supported]
        : [NSString stringWithFormat:@"AB Props (%lu)", (unsigned long)filtered.count];
    self.title = active
        ? [base stringByAppendingFormat:@" · %lu ativos", (unsigned long)active]
        : base;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController {
    [self applyCurrentFilter];
}

- (void)searchBar:(__unused UISearchBar *)searchBar
selectedScopeButtonIndexDidChange:(__unused NSInteger)selectedScope {
    [self applyCurrentFilter];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sectionKeys.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return 0;
    return (NSInteger)self.sections[self.sectionKeys[(NSUInteger)section]].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return nil;
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@ (%lu)",
            key, (unsigned long)self.sections[key].count];
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"Toque para editar por ABI: BOOL, inteiros, float/double e objetos Foundation. "
            "Objetos customizados aceitam Force nil ou substituição Foundation avançada. "
            "Pressão longa abre as mesmas ações; Usar original remove o override persistido.";
}

- (WAGRABPropEntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

static NSString *WAGRABOverrideDescription(id value, BOOL overridden) {
    if (!overridden) return @"";
    if (!value) return @" · FORCE nil";
    NSString *description = [value description] ?: @"?";
    if (description.length > 120) description = [[description substringToIndex:120] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@" · FORCE %@", description];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRABPropsRuntimeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    WAGRABPropEntry *entry = [self entryAtIndexPath:indexPath];
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"abprop");
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 3;
    if (!entry) return cell;

    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className,
                                                   entry.selectorName,
                                                   entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className,
                                         entry.selectorName,
                                         entry.classMethod);

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@",
        entry.classMethod ? @"+ " : @"- ", entry.selectorName];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@\nAtual: %@%@",
        entry.sourceImage ?: @"runtime", entry.className ?: @"",
        entry.typeName ?: @"?", current ?: @"?",
        WAGRABOverrideDescription(forced, overridden)];
    cell.detailTextLabel.textColor = overridden
        ? UIColor.systemCyanColor
        : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class]
            ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self
                       action:@selector(boolSwitchChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle,
                                 kWAGRABSwitchEntryKey,
                                 entry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.enabled = YES;
        toggle.onTintColor = overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    UILongPressGestureRecognizer *longPress = objc_getAssociatedObject(cell, kWAGRABLongPressKey);
    if (!longPress) {
        longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(longPressRow:)];
        longPress.minimumPressDuration = 0.45;
        [cell addGestureRecognizer:longPress];
        objc_setAssociatedObject(cell,
                                 kWAGRABLongPressKey,
                                 longPress,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)boolSwitchChanged:(UISwitch *)sender {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRABSwitchEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className,
                                entry.selectorName,
                                entry.classMethod,
                                entry.typeCode,
                                @(sender.isOn));
    (void)WAGRRuntimeValueInstallHook(entry.className,
                                      entry.selectorName,
                                      entry.classMethod,
                                      entry.typeCode);
    [self applyCurrentFilter];
}

- (void)presentEditorForEntry:(WAGRABPropEntry *)entry fromView:(UIView *)sourceView {
    if (!entry) return;
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
    __weak typeof(self) weakSelf = self;
    WAGRPresentRuntimeValueEditor(self,
        sourceView,
        entry.className,
        entry.selectorName,
        entry.classMethod,
        entry.typeCode,
        current,
        raw,
        ^{
            [weakSelf applyCurrentFilter];
        });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self presentEditorForEntry:[self entryAtIndexPath:indexPath]
                      fromView:[tableView cellForRowAtIndexPath:indexPath]];
}

- (void)longPressRow:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)gesture.view;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (indexPath) {
        [self presentEditorForEntry:[self entryAtIndexPath:indexPath] fromView:cell];
    }
}

- (void)showActiveOverrides {
    self.searchController.searchBar.text = @"";
    self.searchController.searchBar.selectedScopeButtonIndex = WAGRABBrowserScopeOverrides;
    [self applyCurrentFilter];
}

@end
