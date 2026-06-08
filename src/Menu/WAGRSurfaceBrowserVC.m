// WAGRSurfaceBrowserVC.m — unified real runtime browser.
// One browser for WhatsApp executable, one for SharedModules. Sections are
// real Objective-C class names. Rows are only patchable BOOL/char no-arg getters.

#import "WAGRSurfaceBrowserVC.h"
#import "../Runtime/WAGRGateStore.h"
#import <objc/runtime.h>
#import "WAGRMenuTheme.h"

extern BOOL WAGRGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod);
extern void WAGRGateHooksEnsureInstalled(void);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);

static const void *kWAGRSurfaceEntryKey = &kWAGRSurfaceEntryKey;
static UIColor *WAGRRTAcc(void)  { return UIColor.systemCyanColor; }
static UIColor *WAGRRTOff(void)  { return UIColor.systemRedColor; }
static UIColor *WAGRRTSub(void)  { return WAGRMenuSecondaryTextColor(); }

@interface WAGRSurfaceBrowserVC ()
@property(nonatomic, strong) WAGRSurfaceSpec *spec;
@property(nonatomic, strong) NSArray<WAGREntry *> *allEntries;
@property(nonatomic, strong) NSArray<NSString *> *sectionKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<WAGREntry *> *> *sections;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, assign) BOOL didScan;
@end

@implementation WAGRSurfaceBrowserVC

- (instancetype)initWithSpec:(WAGRSurfaceSpec *)spec {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _spec = spec;
    _allEntries = @[];
    _sectionKeys = @[];
    _sections = @{};
    self.title = spec.title ?: @"Runtime";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 66;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"Buscar classe ou método";
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    UIBarButtonItem *scan = [[UIBarButtonItem alloc]
        initWithTitle:@"Scan" style:UIBarButtonItemStylePlain target:self action:@selector(scanNow)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyVisibleOverrides)];
    self.navigationItem.rightBarButtonItems = @[apply, scan];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didScan) [self scanNow];
}

- (void)scanNow {
    self.didScan = YES;
    WAGRSurfaceSpec *spec = self.spec;
    self.title = @"Escaneando…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGREntry *> *entries = [WAGRScanner scanSurface:spec];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allEntries = entries ?: @[];
            [self applyFilter:self.search.searchBar.text ?: @""];
        });
    });
}

- (void)applyFilter:(NSString *)query {
    NSString *q = query.lowercaseString ?: @"";
    NSArray<WAGREntry *> *base = self.allEntries;
    if (q.length) {
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WAGREntry *e, NSDictionary *_) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@",
                             e.className ?: @"", e.selectorName ?: @"", e.displayName ?: @"", e.isClassMethod ? @"class" : @"instance"].lowercaseString;
            return [hay containsString:q];
        }]];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGREntry *> *> *map = [NSMutableDictionary dictionary];
    for (WAGREntry *e in base) {
        NSString *section = e.className.length ? e.className : @"Other";
        if (!map[section]) map[section] = [NSMutableArray array];
        [map[section] addObject:e];
    }

    NSMutableArray<NSString *> *keys = [[map.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] mutableCopy];
    self.sectionKeys = keys ?: @[];
    self.sections = map ?: @{};

    NSUInteger overrides = 0;
    for (WAGREntry *e in base) if (WAGRGateIsSet(e.selectorName)) overrides++;
    self.title = [NSString stringWithFormat:@"%@ (%lu)", self.spec.title ?: @"Runtime", (unsigned long)base.count];
    if (overrides) self.title = [self.title stringByAppendingFormat:@" · %lu ON/OFF", (unsigned long)overrides];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)self.sectionKeys.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@  (%lu)", key, (unsigned long)self.sections[key].count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"Switch ON força YES; switch OFF força NO. Long press limpa override e remove o hook persistido. Aplicar reinstala tudo visível.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return (NSInteger)self.sections[key].count;
}

- (WAGREntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray<WAGREntry *> *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRSurfaceBrowserCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRSurfaceBrowserCell"];

    WAGREntry *e = [self entryAtIndexPath:indexPath];
    WAGRMenuApplyCellStyle(cell, indexPath.row, e.selectorName ?: e.displayName);
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRRTSub();
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (!e) return cell;

    BOOL isSet = WAGRGateIsSet(e.selectorName);
    BOOL value = isSet && WAGRGateGet(e.selectorName);
    cell.textLabel.text = [NSString stringWithFormat:@"%@%@", e.isClassMethod ? @"+ " : @"- ", e.selectorName ?: @"(selector)"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                                  e.className ?: @"", isSet ? (value ? @"override YES" : @"override NO") : @"sem override"];
    cell.detailTextLabel.textColor = isSet ? (value ? WAGRRTAcc() : WAGRRTOff()) : WAGRRTSub();

    UISwitch *sw = (UISwitch *)objc_getAssociatedObject(cell, kWAGRSurfaceEntryKey);
    if (!sw) {
        sw = [[UISwitch alloc] init];
        sw.onTintColor = WAGRRTAcc();
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(cell, kWAGRSurfaceEntryKey, sw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.accessoryView = sw;
    }
    sw.on = isSet && value;
    sw.tag = indexPath.section * 100000 + indexPath.row;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
    lp.minimumPressDuration = 0.45;
    [cell addGestureRecognizer:lp];
    return cell;
}

- (void)installEntry:(WAGREntry *)e {
    if (!e.selectorName.length || !e.className.length) return;
    (void)WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod);
}

- (void)applyVisibleOverrides {
    NSUInteger setCount = 0, installed = 0;
    for (NSString *key in self.sectionKeys) {
        for (WAGREntry *e in self.sections[key]) {
            if (!WAGRGateIsSet(e.selectorName)) continue;
            setCount++;
            if (WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod)) installed++;
        }
    }
    NSUInteger waab = WAGRWAABInstallHooksForAllRuntimeImages();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Aplicar Runtime"
                                                               message:[NSString stringWithFormat:@"Overrides visíveis: %lu\nHooks diretos instalados: %lu\nWAAB central hooks: %lu", (unsigned long)setCount, (unsigned long)installed, (unsigned long)waab]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    [self.tableView reloadData];
}

- (void)switchChanged:(UISwitch *)sw {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(sw.tag % 100000) inSection:(sw.tag / 100000)];
    WAGREntry *e = [self entryAtIndexPath:ip];
    if (!e.selectorName.length) return;

    // OFF is explicit override NO, not clear. Long press clears.
    WAGRGateSet(e.selectorName, sw.isOn);
    [self installEntry:e];
    [self applyFilter:self.search.searchBar.text ?: @""];
}

- (void)longPressRow:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    WAGREntry *e = ip ? [self entryAtIndexPath:ip] : nil;
    if (!e.selectorName.length) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:e.selectorName
                                                                   message:[NSString stringWithFormat:@"%@\n%@\n%@", e.className ?: @"", e.isClassMethod ? @"class method" : @"instance method", WAGRGateIsSet(e.selectorName) ? @"override ativo" : @"sem override"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Limpar override" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        WAGRGateClear(e.selectorName);
        WAGRGateForgetHook(e.className, e.selectorName, e.isClassMethod);
        [self applyFilter:self.search.searchBar.text ?: @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@ %@ %@", e.isClassMethod ? @"+" : @"-", e.className ?: @"", e.selectorName ?: @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGREntry *e = [self entryAtIndexPath:indexPath];
    if (!e.selectorName.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:e.selectorName
                                                               message:[NSString stringWithFormat:@"%@\n%@\n%@", e.className ?: @"", e.isClassMethod ? @"class method" : @"instance method", WAGRGateIsSet(e.selectorName) ? (WAGRGateGet(e.selectorName) ? @"override YES" : @"override NO") : @"sem override"]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
