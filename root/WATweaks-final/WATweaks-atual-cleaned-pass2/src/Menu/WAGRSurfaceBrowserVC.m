// WAGRSurfaceBrowserVC.m — single Runtime Avançado gate editor.
// Uses WAGRGateStore + WAGRGateInstallHookForSelector. It does not restore
// the removed WAGRGatingCatalog / WAGRGatingAreaMenuVC UI paths.

#import "WAGRSurfaceBrowserVC.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRRuntimeClassifier.h"
#import <objc/runtime.h>
#import "WAGRMenuTheme.h"

extern BOOL WAGRGateInstallHookForSelector(NSString *className,
                                            NSString *selectorName,
                                            BOOL isClassMethod);

static const void *kWAGRSurfaceEntryKey = &kWAGRSurfaceEntryKey;

static UIColor *WAGRRTBG(void)   { return WAGRMenuBackgroundColor(); }
static UIColor *WAGRRTCell(void) { return WAGRMenuCellColor(); }
static UIColor *WAGRRTAcc(void)  { return UIColor.systemCyanColor; }
static UIColor *WAGRRTSub(void)  { return WAGRMenuSecondaryTextColor(); }
static UIColor *WAGRRTOff(void)  { return UIColor.systemRedColor; }

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
    self.tableView.estimatedRowHeight = 72;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"Buscar selector ou classe";
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

static NSString *WAGRRTFeatureName(WAGREntry *e) {
    NSString *name = e.displayName.length ? e.displayName : e.selectorName;
    return name.length ? name : @"(sem selector)";
}

static NSString *WAGRRTSectionForEntry(WAGREntry *e) {
    if (e.category.length) return e.category;
    return WAGRRuntimeSectionForSelector(e.selectorName, e.className);
}

- (void)scanNow {
    self.didScan = YES;
    WAGRSurfaceSpec *spec = self.spec;
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
            NSString *prefix = WAGRRuntimePrefixForName(e.selectorName ?: e.displayName ?: @"");
            NSString *subcat = WAGRRuntimeSubcategoryForName(e.selectorName ?: e.displayName ?: @"");
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
                             e.className ?: @"", e.selectorName ?: @"", e.displayName ?: @"", e.category ?: @"", prefix ?: @"", subcat ?: @""].lowercaseString;
            return [hay containsString:q];
        }]];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGREntry *> *> *map = [NSMutableDictionary dictionary];
    for (WAGREntry *e in base) {
        NSString *section = WAGRRTSectionForEntry(e);
        if (!map[section]) map[section] = [NSMutableArray array];
        [map[section] addObject:e];
    }

    self.sectionKeys = [map.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    self.sections = map;

    NSUInteger overrides = 0;
    for (WAGREntry *e in base) if (WAGRGateIsSet(e.selectorName)) overrides++;
    self.title = overrides ? [NSString stringWithFormat:@"%@ (%lu)", self.spec.title ?: @"Runtime", (unsigned long)overrides]
                           : (self.spec.title ?: @"Runtime");
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)self.sectionKeys.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *key = self.sectionKeys[(NSUInteger)section];
    NSUInteger count = self.sections[key].count;
    return [NSString stringWithFormat:@"%@  (%lu)", key, (unsigned long)count];
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
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 2;

    if (!e) return cell;

    BOOL isSet = WAGRGateIsSet(e.selectorName);
    BOOL value = isSet && WAGRGateGet(e.selectorName);
    cell.textLabel.text = WAGRRTFeatureName(e);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · %@",
                                 e.isClassMethod ? @"+" : @"-",
                                 e.className ?: @"",
                                 e.selectorName ?: @"",
                                 isSet ? (value ? @"override ON" : @"override OFF") : @"system"];
    cell.detailTextLabel.textColor = WAGRMenuIsNegativeGateName(e.selectorName) ? WAGRRTOff() : (isSet ? (value ? WAGRRTAcc() : WAGRRTOff()) : WAGRRTSub());

    UISwitch *sw = (UISwitch *)objc_getAssociatedObject(cell, kWAGRSurfaceEntryKey);
    if (!sw) {
        sw = [[UISwitch alloc] init];
        sw.onTintColor = WAGRRTAcc();
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(cell, kWAGRSurfaceEntryKey, sw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.accessoryView = sw;
    }
    sw.on = value;
    sw.tag = indexPath.section * 100000 + indexPath.row;
    return cell;
}

- (void)applyVisibleOverrides {
    NSUInteger setCount = 0, installed = 0, skipped = 0;
    for (NSString *key in self.sectionKeys) {
        for (WAGREntry *e in self.sections[key]) {
            if (!WAGRGateIsSet(e.selectorName)) continue;
            setCount++;
            if (WAGRMenuIsNegativeGateName(e.selectorName) || WAGRMenuIsNegativeGateName(key)) { skipped++; continue; }
            if (WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod)) installed++;
        }
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Aplicar Runtime"
                                                               message:[NSString stringWithFormat:@"Overrides: %lu\nHooks: %lu\nIgnorados negative/kill: %lu", (unsigned long)setCount, (unsigned long)installed, (unsigned long)skipped]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sw {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(sw.tag % 100000) inSection:(sw.tag / 100000)];
    WAGREntry *e = [self entryAtIndexPath:ip];
    if (!e.selectorName.length) return;

    if (sw.isOn) {
        WAGRGateSet(e.selectorName, YES);
        (void)WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod);
    } else {
        WAGRGateClear(e.selectorName);
    }
    [self applyFilter:self.search.searchBar.text ?: @""];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGREntry *e = [self entryAtIndexPath:indexPath];
    if (!e.selectorName.length) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:WAGRRTFeatureName(e)
                                                                   message:e.className
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Force TRUE" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        WAGRGateSet(e.selectorName, YES);
        (void)WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod);
        [self applyFilter:self.search.searchBar.text ?: @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Force FALSE" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        WAGRGateSet(e.selectorName, NO);
        (void)WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod);
        [self applyFilter:self.search.searchBar.text ?: @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Clear / System" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        WAGRGateClear(e.selectorName);
        [self applyFilter:self.search.searchBar.text ?: @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
