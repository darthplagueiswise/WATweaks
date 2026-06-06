#import "WAGRSurfaceBrowserVC.h"
#import "../Runtime/WAGRGateStore.h"
#import <objc/runtime.h>
#import "WAGRMenuTheme.h"

extern BOOL WAGRGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod);

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
    self.tableView.estimatedRowHeight = 86.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Buscar classe ou selector";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
    WAGRStyleSearchBarForGlass(self.search.searchBar);

    UIBarButtonItem *scan = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(scanNow)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc] initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyVisibleOverrides)];
    self.navigationItem.rightBarButtonItems = @[apply, scan];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; WAGRMenuApplyTableStyle(self.tableView, self); WAGRStyleSearchBarForGlass(self.search.searchBar); }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!self.didScan) [self scanNow]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; WAGRApplyLiquidGlassToViewTree(self.view); WAGRStyleSearchBarForGlass(self.search.searchBar); }

static NSString *WAGRRuntimeClassPrefix(NSString *className) {
    if (!className.length) return @"Unknown";
    NSString *s = className;
    NSRange dot = [s rangeOfString:@"."];
    if (dot.location != NSNotFound && dot.location > 0) return [s substringToIndex:dot.location];
    if ([s hasPrefix:@"_TtC"]) {
        NSScanner *scanner = [NSScanner scannerWithString:[s substringFromIndex:4]];
        NSInteger moduleLen = 0;
        if ([scanner scanInteger:&moduleLen]) {
            NSUInteger start = 4 + scanner.scanLocation;
            if (start < s.length && start + (NSUInteger)moduleLen <= s.length) return [s substringWithRange:NSMakeRange(start, (NSUInteger)moduleLen)];
        }
    }
    NSCharacterSet *uppercase = [NSCharacterSet uppercaseLetterCharacterSet];
    NSMutableString *prefix = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        [prefix appendFormat:@"%C", c];
        if (i > 1 && [uppercase characterIsMember:c]) {
            NSString *p = prefix.copy;
            if (p.length >= 3) return p;
        }
        if (prefix.length >= 24) break;
    }
    return prefix.length ? prefix : s;
}

static NSString *WAGRRuntimeMethodPrefix(WAGREntry *e) {
    return [NSString stringWithFormat:@"%@%@", e.isClassMethod ? @"+" : @"-", e.isProperty ? @" property" : @" method"];
}

- (void)scanNow {
    self.didScan = YES;
    WAGRSurfaceSpec *spec = self.spec;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGREntry *> *entries = [WAGRScanner scanSurface:spec];
        dispatch_async(dispatch_get_main_queue(), ^{ self.allEntries = entries ?: @[]; [self applyFilter:self.search.searchBar.text ?: @""]; });
    });
}

- (void)applyFilter:(NSString *)query {
    NSString *q = query.lowercaseString ?: @"";
    NSArray<WAGREntry *> *base = self.allEntries ?: @[];
    if (q.length) {
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WAGREntry *e, NSDictionary *_) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@", e.className ?: @"", e.selectorName ?: @"", e.displayName ?: @"", WAGRRuntimeClassPrefix(e.className)].lowercaseString;
            return [hay containsString:q];
        }]];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGREntry *> *> *map = [NSMutableDictionary dictionary];
    for (WAGREntry *e in base) {
        NSString *section = WAGRRuntimeClassPrefix(e.className);
        if (!map[section]) map[section] = [NSMutableArray array];
        [map[section] addObject:e];
    }
    NSMutableDictionary *sortedMap = [NSMutableDictionary dictionary];
    for (NSString *k in map) {
        sortedMap[k] = [map[k] sortedArrayUsingComparator:^NSComparisonResult(WAGREntry *a, WAGREntry *b) {
            NSComparisonResult r = [a.className localizedCaseInsensitiveCompare:b.className];
            if (r != NSOrderedSame) return r;
            return [a.selectorName localizedCaseInsensitiveCompare:b.selectorName];
        }];
    }
    self.sections = sortedMap;
    self.sectionKeys = [[sortedMap allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self applyFilter:searchController.searchBar.text ?: @""]; WAGRStyleSearchBarForGlass(searchController.searchBar); }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sectionKeys.count ?: 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (!self.sectionKeys.count) return 1;
    NSString *k = self.sectionKeys[(NSUInteger)section];
    return self.sections[k].count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (!self.sectionKeys.count) return nil;
    NSString *k = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@  (%lu)", k, (unsigned long)self.sections[k].count];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (!self.sectionKeys.count) return @"Nenhum selector BOOL encontrado ainda. Toque em Atualizar depois de abrir mais telas do WhatsApp.";
    return nil;
}

- (UITableViewCell *)emptyCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(cell, 0, @"empty");
    cell.textLabel.text = @"Nada encontrado";
    cell.detailTextLabel.text = @"O runtime browser agrupa somente por prefixo de classe. Sem subcategoria semântica inventada.";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (!self.sectionKeys.count) return [self emptyCell];
    NSString *section = self.sectionKeys[(NSUInteger)ip.section];
    WAGREntry *e = self.sections[section][(NSUInteger)ip.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(cell, ip.row, e.selectorName);
    NSString *sel = e.selectorName.length ? e.selectorName : e.displayName;
    cell.textLabel.text = sel ?: @"(sem selector)";
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.textLabel.numberOfLines = 3;
    NSString *key = WAGRGateCanonicalKey(sel);
    BOOL isSet = WAGRGateIsSet(key);
    NSString *state = isSet ? (WAGRGateGet(key) ? @"Override ON" : @"Override OFF") : @"Original";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@", WAGRRuntimeMethodPrefix(e), state, e.className ?: @""];
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.detailTextLabel.numberOfLines = 4;

    UISwitch *sw = [UISwitch new];
    sw.on = isSet && WAGRGateGet(key);
    sw.accessibilityIdentifier = [NSString stringWithFormat:@"%@|%@|%@", e.className ?: @"", e.isClassMethod ? @"1" : @"0", sel ?: @""];
    if (@available(iOS 13.0, *)) sw.onTintColor = UIColor.labelColor;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    lp.minimumPressDuration = 0.45;
    [cell addGestureRecognizer:lp];
    return cell;
}

- (WAGREntry *)entryForSwitch:(UISwitch *)sw {
    NSArray *parts = [sw.accessibilityIdentifier componentsSeparatedByString:@"|"];
    if (parts.count < 3) return nil;
    NSString *className = parts[0];
    BOOL meta = [parts[1] boolValue];
    NSString *sel = parts[2];
    for (WAGREntry *e in self.allEntries) if ([e.className isEqualToString:className] && e.isClassMethod == meta && [e.selectorName isEqualToString:sel]) return e;
    return nil;
}

- (void)switchChanged:(UISwitch *)sw {
    WAGREntry *e = [self entryForSwitch:sw];
    if (!e.selectorName.length) return;
    WAGRGateSet(e.selectorName, sw.isOn);
    WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod);
    [self.tableView reloadData];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    UISwitch *sw = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : nil;
    WAGREntry *e = [self entryForSwitch:sw];
    if (!e.selectorName.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:e.selectorName message:@"Limpar override e esquecer hook persistido?" preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.sourceView = cell;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [a addAction:[UIAlertAction actionWithTitle:@"Limpar" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        WAGRGateClear(e.selectorName);
        WAGRGateForgetHook(e.className, e.selectorName, e.isClassMethod);
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)applyVisibleOverrides {
    NSUInteger installed = 0;
    for (WAGREntry *e in self.allEntries) {
        if (!WAGRGateIsSet(e.selectorName)) continue;
        if (WAGRGateInstallHookForSelector(e.className, e.selectorName, e.isClassMethod)) installed++;
    }
    NSString *msg = [NSString stringWithFormat:@"Overrides no browser: %lu\nHooks instalados/relembrados: %lu", (unsigned long)WAGRGateAllOverrides().count, (unsigned long)installed];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Runtime" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
