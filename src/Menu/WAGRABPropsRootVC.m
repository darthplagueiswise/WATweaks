#import "WAGRABPropsRootVC.h"
#import "WAGRMenuTheme.h"
#import "WAGRLogViewController.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRLog.h"
#import <objc/runtime.h>

extern NSArray<NSString *> *WAGRWAABObservedKeys(void);
extern NSString *WAGRWAABDisplayNameForKey(NSString *key);
extern void WAGRGateHooksEnsureInstalled(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern NSString *WAGRWAABDiagnosticText(void);

@interface WAGRABPropsRootVC () <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSString *> *allKeys;
@property(nonatomic, copy) NSArray<NSString *> *visibleKeys;
@property(nonatomic, copy) NSArray<NSString *> *sectionKeys;
@property(nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *sections;
@property(nonatomic, strong) UISearchController *searchController;
@end

@implementation WAGRABPropsRootVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"ABProperties";
    _allKeys = @[];
    _visibleKeys = @[];
    _sectionKeys = @[];
    _sections = @{};
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 76.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Buscar ABProperty em runtime";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    WAGRStyleSearchBarForGlass(self.searchController.searchBar);

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadRuntimeKeys)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc] initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyHooks)];
    self.navigationItem.rightBarButtonItems = @[apply, refresh];
    [self reloadRuntimeKeys];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    WAGRMenuApplyTableStyle(self.tableView, self);
    WAGRStyleSearchBarForGlass(self.searchController.searchBar);
    [self reloadRuntimeKeys];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRApplyLiquidGlassToViewTree(self.view);
    WAGRStyleSearchBarForGlass(self.searchController.searchBar);
}

- (void)reloadRuntimeKeys {
    WAGRGateHooksEnsureInstalled();
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    NSArray *observed = nil;
    @try { observed = WAGRWAABObservedKeys(); } @catch (__unused NSException *ex) { observed = @[]; }
    for (id key in observed) if ([key isKindOfClass:NSString.class] && [(NSString *)key length]) [set addObject:key];
    for (NSString *stored in WAGRGateAllOverrides()) {
        NSString *display = WAGRGateDisplayKey(stored);
        if (display.length) [set addObject:display];
    }
    self.allKeys = [[set array] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *da = WAGRWAABDisplayNameForKey(a) ?: a;
        NSString *db = WAGRWAABDisplayNameForKey(b) ?: b;
        NSComparisonResult r = [da localizedCaseInsensitiveCompare:db];
        return r == NSOrderedSame ? [a localizedCaseInsensitiveCompare:b] : r;
    }];
    [self applyFilter:self.searchController.searchBar.text ?: @""];
}

- (void)applyFilter:(NSString *)query {
    NSString *q = query.lowercaseString ?: @"";
    NSArray<NSString *> *base = self.allKeys ?: @[];
    if (q.length) {
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *_) {
            NSString *name = WAGRWAABDisplayNameForKey(key) ?: key;
            return [[key lowercaseString] containsString:q] || [[name lowercaseString] containsString:q];
        }]];
    }
    self.visibleKeys = base;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *map = [NSMutableDictionary dictionary];
    for (NSString *key in base) {
        NSString *display = WAGRWAABDisplayNameForKey(key) ?: key;
        NSString *first = display.length ? [[display substringToIndex:1] uppercaseString] : @"#";
        unichar ch = [first characterAtIndex:0];
        if (![[NSCharacterSet letterCharacterSet] characterIsMember:ch] && ![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:ch]) first = @"#";
        if (!map[first]) map[first] = [NSMutableArray array];
        [map[first] addObject:key];
    }
    self.sectionKeys = [[map allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    self.sections = map;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
    WAGRStyleSearchBarForGlass(searchController.searchBar);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sectionKeys.count ?: 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.sectionKeys.count) return 1;
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return self.sections[key].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.sectionKeys.count) return nil;
    NSString *k = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@  (%lu)", k, (unsigned long)self.sections[k].count];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.sectionKeys.count) return @"ABProperties é lido em runtime pelo hook central de bool/string/integer/doubleForKey:defaultValue:. Abra telas do WhatsApp e toque em Atualizar para capturar mais chaves.";
    return nil;
}

- (UITableViewCell *)emptyCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(cell, 0, @"empty");
    cell.textLabel.text = @"Nenhuma ABProperty capturada ainda";
    cell.detailTextLabel.text = @"Abra áreas do WhatsApp para o app consultar MobileConfig/WAAB e volte aqui. O hook central captura as chaves em runtime; não usa JSON exportado.";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.sectionKeys.count) return [self emptyCell];
    NSString *section = self.sectionKeys[(NSUInteger)indexPath.section];
    NSString *key = self.sections[section][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(cell, indexPath.row, key);
    NSString *displayName = WAGRWAABDisplayNameForKey(key) ?: key;
    cell.textLabel.text = displayName.length ? displayName : key;
    cell.textLabel.numberOfLines = 0;
    NSString *canonical = WAGRGateCanonicalKey(key);
    BOOL isSet = WAGRGateIsSet(canonical);
    NSString *state = isSet ? (WAGRGateGet(canonical) ? @"Override ON" : @"Override OFF") : @"Sem override — usando valor original do WhatsApp";
    if (![displayName isEqualToString:key]) cell.detailTextLabel.text = [NSString stringWithFormat:@"Key/ID: %@\n%@", key, state];
    else cell.detailTextLabel.text = state;
    cell.detailTextLabel.numberOfLines = 0;

    UISwitch *sw = [UISwitch new];
    sw.on = isSet && WAGRGateGet(canonical);
    sw.accessibilityIdentifier = key;
    if (@available(iOS 13.0, *)) sw.onTintColor = UIColor.labelColor;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    lp.minimumPressDuration = 0.45;
    [cell addGestureRecognizer:lp];
    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = sw.accessibilityIdentifier;
    if (!key.length) return;
    WAGRGateSet(key, sw.isOn);
    WAGRGateHooksEnsureInstalled();
    [self.tableView reloadData];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    UISwitch *sw = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : nil;
    NSString *key = sw.accessibilityIdentifier;
    if (!key.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:key message:@"Limpar override desta ABProperty?" preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.sourceView = cell;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [a addAction:[UIAlertAction actionWithTitle:@"Limpar override" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        WAGRGateClear(key);
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)applyHooks {
    WAGRGateHooksEnsureInstalled();
    NSString *msg = [NSString stringWithFormat:@"ABProperties capturadas: %lu\nOverrides ativos: %lu\n\n%@",
                     (unsigned long)self.allKeys.count,
                     (unsigned long)WAGRGateAllOverrides().count,
                     WAGRGateHooksDiagnostic() ?: @""];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ABProperties" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused id _) { UIPasteboard.generalPasteboard.string = msg; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end


// MARK: - WAAB on-demand runtime hook install
// This is intentionally triggered only when ABProperties UI is opened.
// It must not run from tweak startup/constructor against WhatsApp runtime classes.

extern NSUInteger WAGRWAABInstallHooksForExecutable(void);
extern NSUInteger WAGRWAABInstallHooksForSharedModules(void);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);

@interface WAGRABPropsRootVC (WAGRWAABOnDemandRuntime)
- (void)applyHooks;
- (void)applyHooksForExecutable;
- (void)applyHooksForSharedModules;
- (void)applyHooksForAllRuntimeImages;
- (void)wagr_waab_onDemand_viewDidAppear:(BOOL)animated;
@end

@implementation WAGRABPropsRootVC (WAGRWAABOnDemandRuntime)

- (void)wagr_waab_reloadVisibleTableIfPossible {
    id tv = nil;
    @try { tv = [self valueForKey:@"tableView"]; } @catch (__unused NSException *ex) { tv = nil; }
    if ([tv respondsToSelector:@selector(reloadData)]) {
        [tv reloadData];
    }
}

- (void)applyHooks {
    [self applyHooksForAllRuntimeImages];
}

- (void)applyHooksForExecutable {
    @try { (void)WAGRWAABInstallHooksForExecutable(); } @catch (__unused NSException *ex) {}
    [self wagr_waab_reloadVisibleTableIfPossible];
}

- (void)applyHooksForSharedModules {
    @try { (void)WAGRWAABInstallHooksForSharedModules(); } @catch (__unused NSException *ex) {}
    [self wagr_waab_reloadVisibleTableIfPossible];
}

- (void)applyHooksForAllRuntimeImages {
    @try { (void)WAGRWAABInstallHooksForAllRuntimeImages(); } @catch (__unused NSException *ex) {}
    [self wagr_waab_reloadVisibleTableIfPossible];
}

- (void)wagr_waab_onDemand_viewDidAppear:(BOOL)animated {
    [self wagr_waab_onDemand_viewDidAppear:animated];
    [self applyHooks];
}

@end

__attribute__((constructor))
static void WAGRABPropsRootVCInstallOnDemandWAABScan(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"WAGRABPropsRootVC");
        if (!cls) return;

        SEL origSel = @selector(viewDidAppear:);
        SEL replSel = @selector(wagr_waab_onDemand_viewDidAppear:);

        Method orig = class_getInstanceMethod(cls, origSel);
        Method repl = class_getInstanceMethod(cls, replSel);
        if (!orig || !repl) return;

        static BOOL didSwap = NO;
        if (didSwap) return;
        didSwap = YES;

        method_exchangeImplementations(orig, repl);
    });
}
