#import "WAGRSurfaceBrowserVC.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "WAGRMenuTheme.h"

extern id WAGRCurrentUserContext(void);

static const void *kWAGRSurfaceEntryKey = &kWAGRSurfaceEntryKey;

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
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *readValueCache;
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
    _readValueCache = [NSMutableDictionary dictionary];
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

    // Own the gesture on the table: late cell renderers must retain Read/Edit.
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(longPressRow:)];
    press.minimumPressDuration = 0.45;
    [self.tableView addGestureRecognizer:press];
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
    // Only already-captured objects; no singleton guesses or dependency walks.
    id context = WAGRCurrentUserContext();
    NSMutableArray *objects = [NSMutableArray array];
    if (context) [objects addObject:context];
    // Deliberate context -> abProperties -> getter reads can reuse the result
    // of an earlier explicit Read without inspecting unrequested dependencies.
    for (NSDictionary *cached in self.readValueCache.allValues) {
        id value = cached[@"raw"];
        if (value && value != NSNull.null) [objects addObject:value];
    }
    return objects;
}

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.didScan = YES;
    [self.readValueCache removeAllObjects];
    self.runtimeObjects = @[];
    self.title = @"Lendo runtime carregado…";
    self.navigationItem.rightBarButtonItems.firstObject.enabled = NO;

    WAGRSurfaceSpec *spec = self.spec;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGREntry *> *entries = [WAGRScanner scanSurface:spec];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.navigationItem.rightBarButtonItems.firstObject.enabled = YES;
            [self.refreshControl endRefreshing];
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
    [self updateEmptyState];
    [self.tableView reloadData];
}

- (void)updateEmptyState {
    if (self.sectionKeys.count) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14.0];
    label.textColor = UIColor.secondaryLabelColor;
    if (!self.allEntries.count && self.spec.runtimeImagePath.length) {
        label.text = self.spec.runtimeImageLoaded
            ? @"Imagem carregada.\n\nNão expõe getters Objective-C sem argumentos\ncom tipos compatíveis e permitidos para edição.\n\nCódigo C/C++ e Swift sem exposição ObjC\nnão pode ser editado por este browser."
            : @"Imagem presente no app, ainda não carregada.\n\nNão há classes ou getters no runtime deste processo.\nO browser não carrega frameworks para inspecioná-los.\n\nAtualize depois que o próprio app usar este módulo.";
    } else {
        label.text = self.allEntries.count ? @"Nenhum resultado para este filtro." : @"Nenhum getter compatível encontrado.";
    }
    self.tableView.backgroundView = label;
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
    return @"Metadados do runtime carregado. Toque para editar; mantenha pressionado para ler "
            "um valor no receiver vivo exato. A lista mostra overrides ou leituras anteriores, "
            "sem executar getters ao rolar ou buscar.";
}

- (WAGREntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

static BOOL WAGRLiveReceiverMatches(id object, Class cls, SEL selector) {
    return object && [object isKindOfClass:cls] && [object respondsToSelector:selector];
}

static id WAGRLiveReceiverInView(UIView *view, Class cls, SEL selector, NSUInteger depth) {
    if (!view || depth > 40) return nil;
    if (WAGRLiveReceiverMatches(view, cls, selector)) return view;
    for (UIView *child in view.subviews) {
        id found = WAGRLiveReceiverInView(child, cls, selector, depth + 1);
        if (found) return found;
    }
    return nil;
}

static id WAGRLiveReceiverInController(UIViewController *controller, Class cls,
                                       SEL selector, NSUInteger depth) {
    if (!controller || depth > 20) return nil;
    if (WAGRLiveReceiverMatches(controller, cls, selector)) return controller;
    UIView *loadedView = controller.isViewLoaded ? controller.view : nil;
    id inView = WAGRLiveReceiverInView(loadedView, cls, selector, 0);
    if (inView) return inView;
    for (UIViewController *child in controller.childViewControllers) {
        id found = WAGRLiveReceiverInController(child, cls, selector, depth + 1);
        if (found) return found;
    }
    return WAGRLiveReceiverInController(controller.presentedViewController, cls, selector, depth + 1);
}

- (id)receiverForEntry:(WAGREntry *)entry {
    if (!entry || entry.isClassMethod ||
        !WAGRRuntimeValueSelectorIsSafeGetter(entry.selectorName)) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    if (!cls) return nil;
    for (id object in self.runtimeObjects) {
        if (![object isKindOfClass:cls]) continue;
        if ([object respondsToSelector:selector]) return object;
    }
    UIApplication *application = UIApplication.sharedApplication;
    if (WAGRLiveReceiverMatches(application.delegate, cls, selector)) return application.delegate;
    for (UIWindow *window in application.windows) {
        if (WAGRLiveReceiverMatches(window, cls, selector)) return window;
        id found = WAGRLiveReceiverInController(window.rootViewController, cls, selector, 0);
        if (found) return found;
    }
    return nil;
}

- (NSString *)currentForEntry:(WAGREntry *)entry raw:(id *)raw {
    if (raw) *raw = nil;
    if (!entry) return @"entrada indisponível";
    if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod)) {
        id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.isClassMethod);
        if (raw) *raw = forced;
        return forced ? [forced description] : @"nil";
    }
    NSString *uid = WAGRRuntimeValueUID(entry.className, entry.selectorName, entry.isClassMethod);
    NSDictionary *cached = self.readValueCache[uid];
    id value = cached[@"raw"];
    if (raw) *raw = value == NSNull.null ? nil : value;
    return cached[@"text"] ?: @"Não lido · mantenha pressionado para ler";
}

- (void)readValueForEntry:(WAGREntry *)entry {
    if (!entry || !WAGRRuntimeValueSelectorIsSafeGetter(entry.selectorName)) return;
    self.runtimeObjects = [self resolveRuntimeObjects];
    id raw = nil;
    NSString *text = WAGRRuntimeValueRead(entry.className, entry.selectorName,
        entry.isClassMethod, [self receiverForEntry:entry], &raw);
    NSString *uid = WAGRRuntimeValueUID(entry.className, entry.selectorName, entry.isClassMethod);
    self.readValueCache[uid] = @{ @"text": [@"Leitura anterior: " stringByAppendingString:text ?: @"?"],
                                  @"raw": raw ?: NSNull.null };
    [self.tableView reloadData];
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
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    WAGREntry *entry = [self entryAtIndexPath:indexPath];
    if (!entry) return;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:entry.selectorName
        message:@"Ler executa este getter uma vez no receiver vivo exato."
        preferredStyle:UIAlertControllerStyleActionSheet];
    menu.popoverPresentationController.sourceView = cell ?: self.tableView;
    menu.popoverPresentationController.sourceRect = cell ? cell.bounds : self.tableView.bounds;
    [menu addAction:[UIAlertAction actionWithTitle:@"Ler valor atual" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [self readValueForEntry:entry]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Editar override" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [self presentEditorForEntry:entry fromView:cell]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
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
