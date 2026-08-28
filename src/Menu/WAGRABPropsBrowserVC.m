#import "WAGRABPropsBrowserVC.h"
#import "WAGRMenuTheme.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRABPropsABTForceFull.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, WAGRABBrowserScope) {
    WAGRABBrowserScopeAll = 0,
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
@property(nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *nativeEntriesBySelector;
@property(nonatomic, strong) WAGRABPropsNativeSnapshot *nativeSnapshot;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UIBarButtonItem *fetchButton;
@property(nonatomic, assign) BOOL didScan;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) BOOL fetching;
@property(nonatomic, copy) NSString *lastFetchNote;
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
    _nativeEntriesBySelector = @{};
    _lastFetchNote = @"";
    self.title = @"WAAB Runtime";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 94.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.placeholder = @"Buscar selector, AB ID ou param";
    search.searchBar.scopeButtonTitles = @[ @"Todos", @"BOOL", @"Números", @"Objetos", @"Overrides" ];
    search.searchBar.selectedScopeButtonIndex = WAGRABBrowserScopeAll;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.searchController = search;
    WAGRMenuApplySearchGlass(search.searchBar);

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(scanNow)];
    self.fetchButton = [[UIBarButtonItem alloc]
        initWithTitle:@"Fetch" style:UIBarButtonItemStyleDone
        target:self action:@selector(fetchNow)];
    self.navigationItem.rightBarButtonItems = @[refresh, self.fetchButton];

    UIRefreshControl *pull = [UIRefreshControl new];
    [pull addTarget:self action:@selector(scanNow) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRMenuApplySearchGlass(self.searchController.searchBar);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self scanNow];
}

#pragma mark - Live/native correlation

static NSDictionary<NSString *, NSDictionary *> *WAGRABNativeIndexForSnapshot(
    WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{};
    NSDictionary *document = WAGRABPropsNativeExportDocument(snapshot);
    NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class]
        ? document[@"entries"] : @[];
    NSMutableDictionary<NSString *, NSDictionary *> *index = [NSMutableDictionary dictionary];
    for (id object in entries) {
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry = object;
        NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : nil;
        if (!name.length || [name hasPrefix:@"ABProp "]) continue;
        if (!index[name]) index[name] = entry;
    }
    return index;
}

- (NSDictionary *)nativeEntryForRuntimeEntry:(WAGRABPropEntry *)entry {
    if (!entry.selectorName.length) return nil;
    return self.nativeEntriesBySelector[entry.selectorName];
}

static NSString *WAGRABCompactValue(id value) {
    if (!value || value == NSNull.null) return @"nil";
    NSString *text = [value description] ?: @"?";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length > 72) text = [[text substringToIndex:72] stringByAppendingString:@"…"];
    return text;
}

static BOOL WAGRABNativeBoolValue(id value, BOOL *known) {
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

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.didScan = YES;
    self.title = @"Lendo WAAB + cache…";

    id context = self.userContext;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = WAGRABPropsResolveRuntimeObjects(context);
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(NULL);
        NSDictionary *nativeIndex = WAGRABNativeIndexForSnapshot(snapshot);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            [self.refreshControl endRefreshing];
            self.runtimeObjects = objects ?: @[];
            self.allEntries = entries ?: @[];
            self.nativeSnapshot = snapshot;
            self.nativeEntriesBySelector = nativeIndex ?: @{};
            [self applyCurrentFilter];
        });
    });
}

#pragma mark - Fetch

static NSString *WAGRABFullFetchSummary(NSDictionary *result) {
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"store_confirmation"] : @{};
    BOOL verified = [result[@"verified"] boolValue];
    BOOL completed = [result[@"native_completion_observed"] boolValue];
    BOOL refilled = [store[@"config_hash_refilled"] boolValue];
    BOOL fingerprintChanged = [store[@"fingerprint_changed"] boolValue];
    NSUInteger count = [store[@"effective_prop_count"] unsignedIntegerValue];
    NSString *outcome = [result[@"outcome"] isKindOfClass:NSString.class]
        ? result[@"outcome"] : @"unknown";
    return [NSString stringWithFormat:
        @"ABT full nativo · reset=YES · completion=%@ · hash=%@ · props=%lu · gabpΔ=%@ · %@%@",
        completed ? @"YES" : @"NO",
        refilled ? @"REFILLED" : @"EMPTY",
        (unsigned long)count,
        fingerprintChanged ? @"YES" : @"NO",
        outcome,
        verified ? @" · VERIFICADO" : @""];
}

- (void)fetchNow {
    if (self.fetching) return;
    self.fetching = YES;
    self.fetchButton.enabled = NO;

    self.title = @"ABT full: limpando hash…";

    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLiveFetchForcedFull(self.userContext,
        ^(NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.fetching = NO;
            self.fetchButton.enabled = YES;
            self.lastFetchNote = WAGRABFullFetchSummary(result);
            [self scanNow];
        }, &diagnostic);
    if (!invoked) {
        self.fetching = NO;
        self.fetchButton.enabled = YES;
        self.lastFetchNote = diagnostic ?: @"Fetch nativo não enviado.";
        [self applyCurrentFilter];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ABProps Fetch"
            message:self.lastFetchNote preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.lastFetchNote = diagnostic ?: @"ABT full nativo enviado; aguardando completion e hash reposto pelo store.";
    [self applyCurrentFilter];
}

#pragma mark - Filter

static NSArray<NSString *> *WAGRABSearchTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [query.lowercaseString componentsSeparatedByCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

static BOOL WAGRABEntryMatchesScope(WAGRABPropEntry *entry, WAGRABBrowserScope scope) {
    switch (scope) {
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
            return WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
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
        if (!WAGRABEntryMatchesScope(entry, scope)) continue;
        NSDictionary *native = [self nativeEntryForRuntimeEntry:entry];
        NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? native[@"mobileconfig"] : @{};
        NSString *liveFamily = WAGRLiveRuntimeFamilyForSelector(entry.selectorName,
                                                                 entry.className);
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@ %@ %@",
            liveFamily ?: @"", entry.categoryName ?: @"", entry.selectorName ?: @"",
            entry.className ?: @"", entry.typeName ?: @"", entry.sourceImage ?: @"",
            native[@"code"] ?: @"", native[@"value"] ?: @"",
            mc[@"parameter_name"] ?: @"", mc[@"config_name"] ?: @""].lowercaseString;
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (![haystack containsString:token]) { matches = NO; break; }
        }
        if (matches) [filtered addObject:entry];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups =
        [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in filtered) {
        NSString *family = WAGRLiveRuntimeFamilyForSelector(entry.selectorName,
                                                             entry.className);
        if (!family.length) family = @"Other Runtime";
        if (!groups[family]) groups[family] = [NSMutableArray array];
        [groups[family] addObject:entry];
    }
    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:
                        @selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups;

    self.title = [NSString stringWithFormat:@"WAAB (%lu)", (unsigned long)filtered.count];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController {
    [self applyCurrentFilter];
}

- (void)searchBar:(__unused UISearchBar *)searchBar
 selectedScopeButtonIndexDidChange:(__unused NSInteger)selectedScope {
    [self applyCurrentFilter];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sectionKeys.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return 0;
    return (NSInteger)self.sections[self.sectionKeys[(NSUInteger)section]].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return nil;
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@ (%lu)", key,
        (unsigned long)self.sections[key].count];
}

- (void)tableView:(__unused UITableView *)tableView
 willDisplayHeaderView:(UIView *)view
        forSection:(__unused NSInteger)section {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.numberOfLines = 0;
    header.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    NSString *base = [NSString stringWithFormat:
        @"WAAB = getters Objective-C carregados agora. Cache nativo = %lu ABProps em gabp.*p; %lu getters desta tela têm correlação direta por stable ID. Fetch relê os dois lados.",
        (unsigned long)self.nativeSnapshot.numericPropCount,
        (unsigned long)self.nativeEntriesBySelector.count];
    return self.lastFetchNote.length
        ? [base stringByAppendingFormat:@"\n%@", self.lastFetchNote]
        : base;
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
    if (description.length > 80) {
        description = [[description substringToIndex:80] stringByAppendingString:@"…"];
    }
    return [NSString stringWithFormat:@" · FORCE %@", description];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRABPropsLiveCell";
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
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
    if (!entry) return cell;

    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className,
                                                   entry.selectorName,
                                                   entry.classMethod);
    BOOL installed = overridden && WAGRRuntimeValueHookIsInstalled(entry.className,
                                                                    entry.selectorName,
                                                                    entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className,
                                         entry.selectorName,
                                         entry.classMethod);
    NSDictionary *native = [self nativeEntryForRuntimeEntry:entry];
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? native[@"mobileconfig"] : @{};

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@",
        entry.classMethod ? @"+ " : @"- ", entry.selectorName];

    NSString *state = overridden ? (installed ? @"INSTALLED" : @"PENDING") : @"ORIGINAL";
    NSMutableString *detail = [NSMutableString stringWithFormat:@"Atual: %@%@ · %@",
        current ?: @"?", WAGRABOverrideDescription(forced, overridden), state];
    if (native) {
        [detail appendFormat:@"\nAB #%@ · cache %@",
            native[@"code"] ?: @"?", WAGRABCompactValue(native[@"value"])];
        NSString *parameterName = [mc[@"parameter_name"] isKindOfClass:NSString.class]
            ? mc[@"parameter_name"] : nil;
        NSString *configName = [mc[@"config_name"] isKindOfClass:NSString.class]
            ? mc[@"config_name"] : nil;
        if (parameterName.length) {
            if (configName.length) [detail appendFormat:@"\nMC: %@.%@", configName, parameterName];
            else [detail appendFormat:@"\nMC param: %@", parameterName];
        }
    }
    cell.detailTextLabel.text = detail;

    BOOL cacheMismatch = NO;
    if (!overridden && native && WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        BOOL known = NO;
        BOOL cacheBool = WAGRABNativeBoolValue(native[@"value"], &known);
        if (known && [raw respondsToSelector:@selector(boolValue)]) {
            cacheMismatch = ([raw boolValue] != cacheBool);
        }
    }
    cell.detailTextLabel.textColor = overridden
        ? (installed ? UIColor.systemCyanColor : UIColor.systemOrangeColor)
        : (cacheMismatch ? UIColor.systemOrangeColor : WAGRMenuSecondaryTextColor());

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class]
            ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:@selector(boolSwitchChanged:)
              forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRABSwitchEntryKey, entry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = overridden
            ? (installed ? UIColor.systemCyanColor : UIColor.systemOrangeColor)
            : UIColor.systemGreenColor;
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
        objc_setAssociatedObject(cell, kWAGRABLongPressKey, longPress,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

#pragma mark - Overrides

- (void)presentPendingForEntry:(WAGRABPropEntry *)entry readback:(NSString *)readback {
    NSString *target = [NSString stringWithFormat:@"%@ %@%@",
        entry.className ?: @"?", entry.classMethod ? @"+" : @"-", entry.selectorName ?: @"?"];
    NSString *message = readback.length
        ? [NSString stringWithFormat:@"O override foi preservado, mas ainda não pôde ser validado no receiver exato.\n\n%@\nReadback: %@\n\nEle permanece PENDING e será tentado novamente quando o runtime estiver disponível.", target, readback]
        : [NSString stringWithFormat:@"O override foi preservado, mas o hook exato ainda não pôde ser instalado.\n\n%@\n\nEle permanece PENDING e será tentado novamente quando o runtime estiver disponível.", target];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Override pendente"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)boolSwitchChanged:(UISwitch *)sender {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRABSwitchEntryKey);
    if (!entry) return;
    BOOL requested = sender.isOn;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, @(requested));
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.classMethod, entry.typeCode);
    if (!installed) {
        sender.on = requested;
        [self presentPendingForEntry:entry readback:nil];
        [self applyCurrentFilter];
        return;
    }

    id readbackRaw = nil;
    NSString *readback = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &readbackRaw);
    BOOL verified = [readbackRaw respondsToSelector:@selector(boolValue)] &&
                    ([readbackRaw boolValue] == requested);
    if (!verified) {
        sender.on = requested;
        [self presentPendingForEntry:entry readback:readback];
    }
    [self applyCurrentFilter];
}

- (void)presentEditorForEntry:(WAGRABPropEntry *)entry fromView:(UIView *)sourceView {
    if (!entry) return;
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
    __weak typeof(self) weakSelf = self;
    WAGRPresentRuntimeValueEditor(self, sourceView,
        entry.className, entry.selectorName, entry.classMethod, entry.typeCode,
        current, raw, ^{
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
    if (indexPath) [self presentEditorForEntry:[self entryAtIndexPath:indexPath] fromView:cell];
}

@end
