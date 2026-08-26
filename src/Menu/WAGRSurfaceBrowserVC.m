#import "WAGRSurfaceBrowserVC.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "WAGRMenuTheme.h"

extern id WAGRCurrentUserContext(void);

static const void *kWAGRSurfaceEntryKey = &kWAGRSurfaceEntryKey;
static const void *kWAGRSurfaceLongPressKey = &kWAGRSurfaceLongPressKey;

typedef NS_ENUM(NSInteger, WAGRLiveBrowserScope) {
    WAGRLiveBrowserScopeAll = 0,
    WAGRLiveBrowserScopeBoolean,
    WAGRLiveBrowserScopeNumeric,
    WAGRLiveBrowserScopeObject,
    WAGRLiveBrowserScopeOverrides,
};

@interface WAGRSurfaceBrowserVC ()
@property(nonatomic, strong) WAGRSurfaceSpec *spec;
@property(nonatomic, strong) NSArray<WAGREntry *> *allEntries;
@property(nonatomic, strong) NSArray<NSString *> *sectionKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<WAGREntry *> *> *sections;
@property(nonatomic, strong) NSArray *runtimeObjects;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, assign) BOOL didScan;
@property(nonatomic, assign) BOOL scanning;
@end

@implementation WAGRSurfaceBrowserVC

- (instancetype)initWithSpec:(WAGRSurfaceSpec *)spec {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _spec = spec;
    _allEntries = @[];
    _sectionKeys = @[];
    _sections = @{};
    _runtimeObjects = @[];
    self.title = spec.title ?: @"Runtime";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 108;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.placeholder = @"Buscar imagem, família, classe, selector ou tipo";
    search.searchBar.scopeButtonTitles = @[ @"Todos", @"BOOL", @"Números", @"Objetos", @"Overrides" ];
    search.searchBar.selectedScopeButtonIndex = WAGRLiveBrowserScopeAll;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.search = search;
    WAGRMenuApplySearchGlass(search.searchBar);

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self
        action:@selector(scanNow)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar"
        style:UIBarButtonItemStyleDone
        target:self
        action:@selector(applyVisibleOverrides)];
    self.navigationItem.rightBarButtonItems = @[apply, refresh];

    UIRefreshControl *pull = [UIRefreshControl new];
    [pull addTarget:self action:@selector(scanNow) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRMenuApplySearchGlass(self.search.searchBar);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didScan) [self scanNow];
}

- (NSArray *)resolveRuntimeObjects {
    id context = WAGRCurrentUserContext();
    NSMutableOrderedSet *objects = [NSMutableOrderedSet orderedSet];
    if (context) [objects addObject:context];
    for (id object in WAGRABPropsResolveRuntimeObjects(context)) {
        if (object) [objects addObject:object];
    }
    return objects.array ?: @[];
}

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.didScan = YES;
    self.title = @"Lendo runtime carregado…";
    self.navigationItem.rightBarButtonItems.firstObject.enabled = NO;

    WAGRSurfaceSpec *spec = self.spec;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = [self resolveRuntimeObjects];
        NSArray<WAGREntry *> *entries = [WAGRScanner scanSurface:spec];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.navigationItem.rightBarButtonItems.firstObject.enabled = YES;
            [self.refreshControl endRefreshing];
            self.runtimeObjects = objects ?: @[];
            self.allEntries = entries ?: @[];
            [self applyCurrentFilter];
        });
    });
}

static NSArray<NSString *> *WAGRLiveBrowserTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [query.lowercaseString componentsSeparatedByCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

static BOOL WAGRLiveEntryMatchesScope(WAGREntry *entry, WAGRLiveBrowserScope scope) {
    switch (scope) {
        case WAGRLiveBrowserScopeAll:
            return YES;
        case WAGRLiveBrowserScopeBoolean:
            return WAGRRuntimeValueTypeIsBoolean(entry.typeCode);
        case WAGRLiveBrowserScopeNumeric:
            return WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
                   WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode) ||
                   WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode);
        case WAGRLiveBrowserScopeObject:
            return WAGRRuntimeValueTypeIsObject(entry.typeCode);
        case WAGRLiveBrowserScopeOverrides:
            return WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
                                               entry.isClassMethod);
    }
    return YES;
}

- (NSString *)sectionForEntry:(WAGREntry *)entry {
    if (self.spec.runtimeFamilyKey.length) {
        return [NSString stringWithFormat:@"%@ — %@",
            entry.imageName.length ? entry.imageName : @"Runtime",
            entry.className.length ? entry.className : @"Unknown"];
    }
    if (self.spec.runtimeImagePath.length) {
        return entry.runtimeFamily.length ? entry.runtimeFamily
                                          : (entry.className.length ? entry.className : @"Other Runtime");
    }
    return entry.runtimeSubcategory.length ? entry.runtimeSubcategory
                                           : (entry.className.length ? entry.className : @"Other Runtime");
}

- (void)applyCurrentFilter {
    NSString *query = self.search.searchBar.text ?: @"";
    NSArray<NSString *> *tokens = WAGRLiveBrowserTokens(query);
    WAGRLiveBrowserScope scope = (WAGRLiveBrowserScope)self.search.searchBar.selectedScopeButtonIndex;

    NSMutableArray<WAGREntry *> *filtered = [NSMutableArray array];
    for (WAGREntry *entry in self.allEntries) {
        if (!WAGRLiveEntryMatchesScope(entry, scope)) continue;
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@",
            entry.imageName ?: @"", entry.imagePath ?: @"", entry.runtimeFamily ?: @"",
            entry.runtimeSubcategory ?: @"", entry.className ?: @"",
            entry.selectorName ?: @"", entry.typeName ?: @"",
            entry.isClassMethod ? @"class" : @"instance"].lowercaseString;
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (![haystack containsString:token]) { matches = NO; break; }
        }
        if (matches) [filtered addObject:entry];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGREntry *> *> *groups =
        [NSMutableDictionary dictionary];
    for (WAGREntry *entry in filtered) {
        NSString *section = [self sectionForEntry:entry];
        if (!groups[section]) groups[section] = [NSMutableArray array];
        [groups[section] addObject:entry];
    }
    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:
                        @selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups;

    NSUInteger active = 0;
    for (WAGREntry *entry in filtered) {
        if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
                                        entry.isClassMethod)) active++;
    }
    NSString *base = [NSString stringWithFormat:@"%@ (%lu)", self.spec.title ?: @"Runtime",
                      (unsigned long)filtered.count];
    self.title = active ? [base stringByAppendingFormat:@" · %lu ativos", (unsigned long)active]
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
    header.textLabel.textColor = WAGRMenuSecondaryTextColor();
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"Este conteúdo é reconstruído ao abrir ou atualizar: imagem Mach-O, classe, selector, "
            "class/instance e ABI são lidos do runtime atual. Toque para editar BOOL, inteiros, "
            "float/double ou objetos Foundation; Usar original remove somente o alvo exato.";
}

- (WAGREntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

static id WAGRLiveSharedReceiver(Class cls, SEL selector) {
    if (!cls || !selector) return nil;
    for (NSString *name in @[ @"shared", @"sharedInstance", @"current", @"defaultInstance",
                               @"defaultManager", @"manager", @"provider", @"properties" ]) {
        SEL factory = NSSelectorFromString(name);
        Method method = class_getClassMethod(cls, factory);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char type[32] = {0};
        method_getReturnType(method, type, sizeof(type));
        if (type[0] != '@') continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(cls, factory);
            if (value && [value isKindOfClass:cls] && [value respondsToSelector:selector]) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

- (id)receiverForEntry:(WAGREntry *)entry {
    if (!entry || entry.isClassMethod) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    if (!cls) return nil;
    for (id object in self.runtimeObjects) {
        if (![object isKindOfClass:cls]) continue;
        if ([object respondsToSelector:selector]) return object;
    }
    return WAGRLiveSharedReceiver(cls, selector);
}

- (NSString *)currentForEntry:(WAGREntry *)entry raw:(id *)raw {
    return WAGRRuntimeValueRead(entry.className, entry.selectorName,
                                entry.isClassMethod, [self receiverForEntry:entry], raw);
}

static NSString *WAGRLiveForcedDescription(id value, BOOL overridden) {
    if (!overridden) return @"";
    if (!value) return @" · FORCE nil";
    NSString *description = [value description] ?: @"?";
    if (description.length > 140) {
        description = [[description substringToIndex:140] stringByAppendingString:@"…"];
    }
    return [NSString stringWithFormat:@" · FORCE %@", description];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRLiveSurfaceBrowserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    WAGREntry *entry = [self entryAtIndexPath:indexPath];
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: entry.displayName);
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
    NSString *current = [self currentForEntry:entry raw:&raw];
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
                                                   entry.isClassMethod);
    BOOL installed = overridden && WAGRRuntimeValueHookIsInstalled(entry.className,
                                                                    entry.selectorName,
                                                                    entry.isClassMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName,
                                         entry.isClassMethod);

    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@",
        entry.isClassMethod ? @"+" : @"-", entry.selectorName];
    NSString *state = overridden ? (installed ? @"INSTALLED" : @"PENDING") : @"ORIGINAL";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@ · %@\nAtual: %@%@ · %@",
        entry.imageName ?: @"Runtime", entry.runtimeFamily ?: @"Other",
        entry.className ?: @"Unknown", entry.typeName ?: @"?", current ?: @"?",
        WAGRLiveForcedDescription(forced, overridden), state];
    cell.detailTextLabel.textColor = overridden
        ? (installed ? UIColor.systemCyanColor : UIColor.systemOrangeColor)
        : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class]
            ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:@selector(switchChanged:)
              forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRSurfaceEntryKey, entry,
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

    UILongPressGestureRecognizer *press = objc_getAssociatedObject(cell, kWAGRSurfaceLongPressKey);
    if (!press) {
        press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
        press.minimumPressDuration = 0.45;
        [cell addGestureRecognizer:press];
        objc_setAssociatedObject(cell, kWAGRSurfaceLongPressKey, press,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)presentPendingForEntry:(WAGREntry *)entry readback:(NSString *)readback {
    NSString *target = [NSString stringWithFormat:@"%@ %@%@",
        entry.className ?: @"?", entry.isClassMethod ? @"+" : @"-", entry.selectorName ?: @"?"];
    NSString *message = readback.length
        ? [NSString stringWithFormat:@"O override foi preservado, mas ainda não pôde ser validado no receiver exato.\n\n%@\nReadback: %@\n\nEle permanece PENDING e será tentado novamente em Aplicar/reinício.", target, readback]
        : [NSString stringWithFormat:@"O override foi preservado, mas o hook exato ainda não pôde ser instalado.\n\n%@\n\nEle permanece PENDING e será tentado novamente em Aplicar/reinício.", target];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Override pendente"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sender {
    WAGREntry *entry = objc_getAssociatedObject(sender, kWAGRSurfaceEntryKey);
    if (!entry) return;
    BOOL requested = sender.isOn;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.isClassMethod, entry.typeCode, @(requested));
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.isClassMethod, entry.typeCode);
    if (!installed) {
        sender.on = requested;
        [self presentPendingForEntry:entry readback:nil];
        [self applyCurrentFilter];
        return;
    }

    id readbackRaw = nil;
    NSString *readback = [self currentForEntry:entry raw:&readbackRaw];
    BOOL verified = [readbackRaw respondsToSelector:@selector(boolValue)] &&
                    ([readbackRaw boolValue] == requested);
    if (!verified) {
        sender.on = requested;
        [self presentPendingForEntry:entry readback:readback];
    }
    [self applyCurrentFilter];
}

- (void)presentEditorForEntry:(WAGREntry *)entry fromView:(UIView *)sourceView {
    if (!entry) return;
    id raw = nil;
    NSString *current = [self currentForEntry:entry raw:&raw];
    __weak typeof(self) weakSelf = self;
    WAGRPresentRuntimeValueEditor(self, sourceView,
        entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode,
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

- (void)applyVisibleOverrides {
    NSUInteger active = 0;
    NSUInteger installed = 0;
    for (NSString *key in self.sectionKeys) {
        for (WAGREntry *entry in self.sections[key]) {
            if (!WAGRRuntimeValueHasOverride(entry.className, entry.selectorName,
                                             entry.isClassMethod)) continue;
            active++;
            if (WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                            entry.isClassMethod, entry.typeCode)) installed++;
        }
    }
    NSUInteger pending = active >= installed ? active - installed : 0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Aplicar Runtime"
        message:[NSString stringWithFormat:@"Overrides visíveis: %lu\nHooks exatos instalados: %lu\nPendentes: %lu",
                 (unsigned long)active, (unsigned long)installed, (unsigned long)pending]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self applyCurrentFilter];
}

@end