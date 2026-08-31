#import "WAGRABPropsBrowserVC.h"
#import "WAGRMenuTheme.h"
#import "WAGRABPropsNativeEditor.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsABTLiveService.h"
#import "../Runtime/WAGRABPropsNativeOverrideEngine.h"
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
@property(nonatomic, strong) id explicitABProperties;
@property(nonatomic, strong) NSArray *runtimeObjects;
@property(nonatomic, strong) NSArray<WAGRABPropEntry *> *allEntries;
@property(nonatomic, strong) NSArray<NSString *> *sectionKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<WAGRABPropEntry *> *> *sections;
@property(nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *nativeEntriesBySelector;
@property(nonatomic, copy) NSDictionary *nativeDocument;
@property(nonatomic, copy) NSDictionary *verifiedABTFetchResult;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UIBarButtonItem *fetchButton;
@property(nonatomic, assign) BOOL didScan;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) BOOL fetching;
@property(nonatomic, copy) NSString *lastFetchNote;
@end

@implementation WAGRABPropsBrowserVC

- (instancetype)initWithUserContext:(id)userContext {
    return [self initWithUserContext:userContext abProperties:nil];
}

- (instancetype)initWithUserContext:(id)userContext abProperties:(id)abProperties {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _userContext = userContext;
    _explicitABProperties = abProperties;
    _runtimeObjects = @[];
    _allEntries = @[];
    _sectionKeys = @[];
    _sections = @{};
    _nativeEntriesBySelector = @{};
    _lastFetchNote = @"";
    self.title = [self wagrInitialABPropertiesTitle];
    return self;
}

- (NSString *)wagrInitialABPropertiesTitle {
    return @"WAAB Runtime";
}

- (NSString *)wagrABPropertiesTitleForEntryCount:(NSUInteger)entryCount {
    return [NSString stringWithFormat:@"WAAB (%lu)", (unsigned long)entryCount];
}

- (BOOL)wagrUsesNativeABPropertiesWriter {
    return NO;
}

- (BOOL)wagrAllowsRuntimeABPropertiesFallback {
    return YES;
}

- (BOOL)wagrScopesToExplicitABProperties {
    return NO;
}

- (BOOL)wagrShowsABTFetchControl {
    return YES;
}

- (BOOL)wagrShowsDiagnosticFooter {
    return YES;
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
    search.searchBar.placeholder = @"Buscar selector, AB ID ou valor";
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
    if ([self wagrShowsABTFetchControl]) {
        self.fetchButton = [[UIBarButtonItem alloc]
            initWithTitle:@"Fetch" style:UIBarButtonItemStyleDone
            target:self action:@selector(fetchNow)];
        self.navigationItem.rightBarButtonItems = @[refresh, self.fetchButton];
    } else {
        self.navigationItem.rightBarButtonItem = refresh;
    }

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

static NSDictionary<NSString *, NSDictionary *> *WAGRABNativeIndexForDocument(
    NSDictionary *document) {
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

static BOOL WAGRABDocumentsIdentifySameStoreState(NSDictionary *left,
                                                   NSDictionary *right) {
    if (![left isKindOfClass:NSDictionary.class] ||
        ![right isKindOfClass:NSDictionary.class] || !left.count || !right.count) return NO;
    NSString *leftFingerprint = [left[@"fingerprint"] isKindOfClass:NSString.class]
        ? left[@"fingerprint"] : @"";
    NSString *rightFingerprint = [right[@"fingerprint"] isKindOfClass:NSString.class]
        ? right[@"fingerprint"] : @"";
    NSString *leftStore = [left[@"store_identity"] isKindOfClass:NSString.class]
        ? left[@"store_identity"] : @"";
    NSString *rightStore = [right[@"store_identity"] isKindOfClass:NSString.class]
        ? right[@"store_identity"] : @"";
    return leftFingerprint.length && [leftFingerprint isEqualToString:rightFingerprint] &&
           leftStore.length && [leftStore isEqualToString:rightStore] &&
           [left[@"prop_count"] unsignedIntegerValue] ==
               [right[@"prop_count"] unsignedIntegerValue];
}

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.didScan = YES;
    self.title = @"Lendo WAAB + cache…";

    id context = self.userContext;
    id exactABProperties = self.explicitABProperties;
    // WAContext/WAContextMain getters are account/session owned. Resolve that
    // object graph on the main thread, then do only method-list decoding and
    // store parsing on the worker queue. The reconstructed native Developer
    // controller always supplies WAContext.abProperties explicitly.
    NSMutableOrderedSet *resolvedObjects = [NSMutableOrderedSet orderedSet];
    if (exactABProperties) [resolvedObjects addObject:exactABProperties];
    if (![self wagrScopesToExplicitABProperties] || !exactABProperties) {
        for (id object in WAGRABPropsResolveRuntimeObjects(context)) {
            if (object) [resolvedObjects addObject:object];
        }
    }
    NSArray *accountRuntimeObjects = resolvedObjects.array ?: @[];
    NSDictionary *verifiedDocument = self.verifiedABTFetchResult.count
        ? self.verifiedABTFetchResult[@"effective_snapshot"] : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = accountRuntimeObjects;
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        NSError *snapshotError = nil;
        // Always reread the exact WAPropertiesStore. A previously verified
        // document is provenance, not a frozen browser cache.
        NSDictionary *document = WAGRABPropsABTAccountSnapshotDocument(context, &snapshotError);
        BOOL verifiedStateStillCurrent = verifiedDocument.count &&
            WAGRABDocumentsIdentifySameStoreState(document, verifiedDocument);
        NSDictionary *nativeIndex = WAGRABNativeIndexForDocument(document ?: @{});

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            [self.refreshControl endRefreshing];
            self.runtimeObjects = objects ?: @[];
            self.allEntries = entries ?: @[];
            self.nativeDocument = document ?: @{};
            self.nativeEntriesBySelector = nativeIndex ?: @{};
            if (self.verifiedABTFetchResult.count && !verifiedStateStillCurrent) {
                self.verifiedABTFetchResult = nil;
                if (document.count) {
                    self.lastFetchNote = @"O WAPropertiesStore mudou depois da transação verificada; a tela releu o estado atual e removeu somente o selo de proveniência daquela transação.";
                }
            }
            if (!document.count && snapshotError.localizedDescription.length) {
                self.lastFetchNote = snapshotError.localizedDescription;
            }
            [self applyCurrentFilter];
        });
    });
}

#pragma mark - Fetch

static NSString *WAGRABFullFetchSummary(NSDictionary *result) {
    NSDictionary *didSucceed = [result[@"did_succeed_response"] isKindOfClass:NSDictionary.class]
        ? result[@"did_succeed_response"] : @{};
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"store_confirmation"] : @{};
    return [NSString stringWithFormat:
        @"SERVER/IQ/STORE VERIFICADO · %@ · wire=%lu · store=%lu · hash=%@ · metadata=%@",
        didSucceed[@"response_description"] ?: @"XMPPIQStanza",
        (unsigned long)[result[@"wire_prop_count"] unsignedIntegerValue],
        (unsigned long)[result[@"effective_prop_count"] unsignedIntegerValue],
        [store[@"reset_hash_refilled"] boolValue] ? @"REFILLED" : @"INVALID",
        [store[@"metadata_matches"] boolValue] ? @"MATCH" : @"MISMATCH"];
}

- (void)fetchNow {
    if (self.fetching) return;
    self.fetching = YES;
    self.fetchButton.enabled = NO;
    self.title = @"ABT server: aguardando IQ…";

    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLiveFetchVariant(
        WAGRABPropsABTVariantFullEmptyHash, self.userContext,
        ^(NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.fetching = NO;
            self.fetchButton.enabled = YES;
            NSString *proof = nil;
            if (!WAGRABPropsABTVerifiedFullEmptyHashResult(result, &proof)) {
                self.lastFetchNote = proof ?: @"ABT server fetch não confirmado.";
                [self applyCurrentFilter];
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"ABT não confirmado"
                    message:self.lastFetchNote preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
                    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                        UIPasteboard.generalPasteboard.string = self.lastFetchNote;
                    }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            self.verifiedABTFetchResult = result;
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
    self.lastFetchNote = diagnostic
        ?: @"full_empty_hash enviado; aguardando XMPPIQStanza, handler full e store exato.";
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
            return YES;
    }
    return YES;
}

- (void)applyCurrentFilter {
    NSString *query = self.searchController.searchBar.text ?: @"";
    NSArray<NSString *> *tokens = WAGRABSearchTokens(query);
    WAGRABBrowserScope scope = (WAGRABBrowserScope)self.searchController.searchBar.selectedScopeButtonIndex;

    NSMutableArray<WAGRABPropEntry *> *filtered = [NSMutableArray array];
    NSDictionary<NSString *, id> *nativeOverrides = [self wagrUsesNativeABPropertiesWriter]
        ? WAGRABPropsNativeTrackedOverrides() : @{};
    for (WAGRABPropEntry *entry in self.allEntries) {
        if (!WAGRABEntryMatchesScope(entry, scope)) continue;
        if (scope == WAGRABBrowserScopeOverrides) {
            BOOL hasOverride = [self wagrUsesNativeABPropertiesWriter]
                ? (entry.stableID.length && nativeOverrides[entry.stableID] != nil)
                : WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
                                              entry.classMethod);
            if (!hasOverride) continue;
        }
        NSDictionary *native = [self nativeEntryForRuntimeEntry:entry];
        NSString *liveFamily = WAGRLiveRuntimeFamilyForSelector(entry.selectorName,
                                                                 entry.className);
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@",
            liveFamily ?: @"", entry.categoryName ?: @"", entry.selectorName ?: @"",
            entry.className ?: @"", entry.typeName ?: @"", entry.sourceImage ?: @"",
            native[@"code"] ?: @"", native[@"value"] ?: @""].lowercaseString;
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

    self.title = [self wagrABPropertiesTitleForEntryCount:filtered.count];
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
    if (![self wagrShowsDiagnosticFooter]) return nil;
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    BOOL verified = self.verifiedABTFetchResult.count > 0;
    NSString *writer = [self wagrUsesNativeABPropertiesWriter]
        ? @"Esta reconstrução usa exclusivamente FBMobileConfigStartupConfigs, exige persistência no App Group, invalida o UserSession e confirma o getter efetivo; não instala swizzle."
        : @"O editor WAAB independente oferece o fallback runtime explicitamente identificado quando solicitado.";
    NSString *base = [NSString stringWithFormat:
        @"WAAB = getters Objective-C reais avaliados ao recarregar. O ABT source é relido do WAPropertiesStore exato. Fonte atual = %@ store da conta, %lu props; %lu getters têm correlação por stable ID. %@",
        verified ? @"SERVER-VERIFICADA no" : @"cache local exato do",
        (unsigned long)[self.nativeDocument[@"prop_count"] unsignedIntegerValue],
        (unsigned long)self.nativeEntriesBySelector.count,
        writer];
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
    if (!value) return @" · RUNTIME FORCE nil";
    NSString *description = [value description] ?: @"?";
    if (description.length > 80) {
        description = [[description substringToIndex:80] stringByAppendingString:@"…"];
    }
    return [NSString stringWithFormat:@" · RUNTIME FORCE %@", description];
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
    BOOL nativeWriter = [self wagrUsesNativeABPropertiesWriter];
    NSDictionary<NSString *, id> *nativeOverrides = nativeWriter
        ? WAGRABPropsNativeTrackedOverrides() : @{};
    id nativeForced = entry.stableID.length ? nativeOverrides[entry.stableID] : nil;
    BOOL overridden = nativeWriter
        ? (nativeForced != nil)
        : WAGRRuntimeValueHasOverride(entry.className,
                                      entry.selectorName,
                                      entry.classMethod);
    BOOL installed = nativeWriter
        ? overridden
        : (overridden && WAGRRuntimeValueHookIsInstalled(entry.className,
                                                          entry.selectorName,
                                                          entry.classMethod));
    id forced = nativeWriter
        ? nativeForced
        : WAGRRuntimeValueOverride(entry.className,
                                   entry.selectorName,
                                   entry.classMethod);
    NSDictionary *native = [self nativeEntryForRuntimeEntry:entry];

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@",
        entry.classMethod ? @"+ " : @"- ", entry.selectorName];

    NSString *state = nativeWriter
        ? (overridden ? @"STARTUPCONFIGS OVERRIDE" : @"EFFECTIVE")
        : (overridden ? (installed ? @"RUNTIME INSTALLED" : @"RUNTIME PENDING")
                      : @"ORIGINAL");
    NSMutableString *detail = [NSMutableString stringWithFormat:@"Atual: %@%@ · %@",
        current ?: @"?",
        nativeWriter
            ? (overridden ? [NSString stringWithFormat:@" · NATIVE %@", forced ?: @"nil"] : @"")
            : WAGRABOverrideDescription(forced, overridden),
        state];
    if (native) {
        [detail appendFormat:@"\nAB #%@ · %@ %@",
            native[@"code"] ?: @"?",
            self.verifiedABTFetchResult.count ? @"server/store" : @"store local",
            WAGRABCompactValue(native[@"value"])];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Override runtime pendente"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)boolSwitchChanged:(UISwitch *)sender {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRABSwitchEntryKey);
    if (!entry) return;
    BOOL requested = sender.isOn;
    if ([self wagrUsesNativeABPropertiesWriter]) {
        sender.enabled = NO;
        NSError *error = nil;
        NSString *diagnostic = nil;
        BOOL applied = entry.stableID.length &&
            WAGRABPropsNativeSetOverride(entry.stableID, @(requested), self.userContext,
                                         &error, &diagnostic);
        sender.enabled = YES;
        if (!applied) {
            id raw = nil;
            WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
            sender.on = [raw respondsToSelector:@selector(boolValue)]
                ? [raw boolValue] : !requested;
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"AB Properties"
                message:error.localizedDescription ?: diagnostic ?:
                    @"O writer nativo rejeitou o override. Nenhum swizzle foi instalado."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        [self scanNow];
        return;
    }
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
    __weak typeof(self) weakSelf = self;
    if ([self wagrUsesNativeABPropertiesWriter]) {
        dispatch_block_t runtimeFallback = nil;
        if ([self wagrAllowsRuntimeABPropertiesFallback]) {
            runtimeFallback = ^{
                id raw = nil;
                NSString *current = WAGRABPropsCurrentValue(
                    entry, weakSelf.runtimeObjects, &raw);
                WAGRPresentRuntimeValueEditor(
                    weakSelf, sourceView, entry.className, entry.selectorName,
                    entry.classMethod, entry.typeCode, current, raw, ^{
                        [weakSelf applyCurrentFilter];
                    });
            };
        }
        WAGRPresentABPropsNativeEditor(
            self, sourceView, entry, self.runtimeObjects, self.userContext,
            entry.stableID, runtimeFallback, ^{
                [weakSelf scanNow];
            });
        return;
    }
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
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
