#import "WAGRSurfaceBrowserVC.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeClassifier.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#import "WAGRMenuTheme.h"

extern id WAGRCurrentUserContext(void);

static const void *kWAGRSurfaceEntryKey = &kWAGRSurfaceEntryKey;
static const void *kWAGRSurfaceLongPressKey = &kWAGRSurfaceLongPressKey;

@interface WAGRSurfaceBrowserVC ()
@property(nonatomic, strong) WAGRSurfaceSpec *spec;
@property(nonatomic, strong) NSArray<WAGREntry *> *allEntries;
@property(nonatomic, strong) NSArray<NSString *> *sectionKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<WAGREntry *> *> *sections;
@property(nonatomic, strong) NSArray *runtimeObjects;
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
    _runtimeObjects = @[];
    self.title = spec.title ?: @"Runtime";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 72;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Buscar área, classe, método ou tipo";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    UIBarButtonItem *scan = [[UIBarButtonItem alloc] initWithTitle:@"Scan" style:UIBarButtonItemStylePlain target:self action:@selector(scanNow)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc] initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyVisibleOverrides)];
    self.navigationItem.rightBarButtonItems = @[apply, scan];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didScan) [self scanNow];
}

- (NSArray *)resolveRuntimeObjects {
    id context = WAGRCurrentUserContext();
    NSString *surfaceID = self.spec.surfaceID.lowercaseString ?: @"";
    if ([surfaceID isEqualToString:@"waab"] || [surfaceID isEqualToString:@"privateexperimentation"]) {
        return WAGRABPropsResolveRuntimeObjects(context);
    }
    return context ? @[context] : @[];
}

- (void)scanNow {
    self.didScan = YES;
    WAGRSurfaceSpec *spec = self.spec;
    self.title = @"Escaneando…";
    NSArray *objects = [self resolveRuntimeObjects];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGREntry *> *entries = [WAGRScanner scanSurface:spec];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runtimeObjects = objects ?: @[];
            self.allEntries = entries ?: @[];
            [self applyFilter:self.search.searchBar.text ?: @""];
        });
    });
}

- (void)applyFilter:(NSString *)query {
    NSArray<NSString *> *tokens = [[query lowercaseString]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<WAGREntry *> *base = self.allEntries;
    if (query.length) {
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WAGREntry *entry, __unused NSDictionary *bindings) {
            NSString *runtimeSection = WAGRRuntimeSectionForSelector(entry.selectorName, entry.className);
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
                entry.className ?: @"", entry.selectorName ?: @"", entry.displayName ?: @"",
                entry.typeName ?: @"", runtimeSection ?: @"",
                entry.isClassMethod ? @"class" : @"instance"].lowercaseString;
            for (NSString *token in tokens) {
                if (token.length && ![haystack containsString:token]) return NO;
            }
            return YES;
        }]];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGREntry *> *> *groups = [NSMutableDictionary dictionary];
    for (WAGREntry *entry in base) {
        NSString *section = WAGRRuntimeSectionForSelector(entry.selectorName, entry.className);
        if (!section.length) section = entry.className.length ? entry.className : @"Other — General";
        if (!groups[section]) groups[section] = [NSMutableArray array];
        [groups[section] addObject:entry];
    }
    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups;

    NSUInteger active = 0;
    for (WAGREntry *entry in base) {
        if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod)) active++;
    }
    self.title = [NSString stringWithFormat:@"%@ (%lu%@)", self.spec.title ?: @"Runtime",
                  (unsigned long)base.count,
                  active ? [NSString stringWithFormat:@" · %lu overrides", (unsigned long)active] : @""];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sectionKeys.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@ (%lu)", key, (unsigned long)self.sections[key].count];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"Agrupado por área/prefixo, com gates negativos separados. Overrides usam "
            "classe + class/instance + selector. BOOL, inteiros, float/double e objetos "
            "Foundation recebem trampolines específicos para a ABI.";
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return (NSInteger)self.sections[key].count;
}

- (WAGREntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (id)receiverForEntry:(WAGREntry *)entry {
    if (!entry || entry.isClassMethod) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    for (id object in self.runtimeObjects) {
        if (cls && ![object isKindOfClass:cls]) continue;
        if ([object respondsToSelector:selector]) return object;
    }
    for (id object in self.runtimeObjects) {
        if ([object respondsToSelector:selector]) return object;
    }
    return nil;
}

- (NSString *)currentForEntry:(WAGREntry *)entry raw:(id *)raw {
    return WAGRRuntimeValueRead(entry.className, entry.selectorName, entry.isClassMethod,
                                [self receiverForEntry:entry], raw);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRSurfaceBrowserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    WAGREntry *entry = [self entryAtIndexPath:indexPath];
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: entry.displayName);
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 3;
    if (!entry) return cell;

    id raw = nil;
    NSString *current = [self currentForEntry:entry raw:&raw];
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.isClassMethod);
    NSString *forcedDescription = forced ? [forced description] : @"nil";

    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", entry.isClassMethod ? @"+" : @"-", entry.selectorName];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\nAtual: %@%@",
        entry.className, entry.typeName ?: @"?", current ?: @"?",
        overridden ? [NSString stringWithFormat:@" · FORCE %@", forcedDescription] : @""];
    cell.detailTextLabel.textColor = overridden ? UIColor.systemCyanColor : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRSurfaceEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor;
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
        objc_setAssociatedObject(cell, kWAGRSurfaceLongPressKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    WAGREntry *entry = objc_getAssociatedObject(sender, kWAGRSurfaceEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode, @(sender.isOn));
    (void)WAGRRuntimeValueInstallHook(entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode);
    [self applyFilter:self.search.searchBar.text ?: @""];
}

- (void)presentEditorForEntry:(WAGREntry *)entry fromView:(UIView *)sourceView {
    if (!entry) return;
    id raw = nil;
    NSString *current = [self currentForEntry:entry raw:&raw];
    __weak typeof(self) weakSelf = self;
    WAGRPresentRuntimeValueEditor(self, sourceView,
        entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode,
        current, raw, ^{
            [weakSelf applyFilter:weakSelf.search.searchBar.text ?: @""];
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
            if (!WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod)) continue;
            active++;
            if (WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                            entry.isClassMethod, entry.typeCode)) installed++;
        }
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Aplicar Runtime"
        message:[NSString stringWithFormat:@"Overrides visíveis: %lu\nHooks tipados instalados: %lu",
                 (unsigned long)active, (unsigned long)installed]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
