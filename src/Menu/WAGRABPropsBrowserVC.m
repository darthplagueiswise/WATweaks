#import "WAGRABPropsBrowserVC.h"
#import "WAGRMenuTheme.h"
#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import <objc/runtime.h>

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
    self.tableView.estimatedRowHeight = 70.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Buscar nome, classe ou tipo";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
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
            [self applyFilter:self.searchController.searchBar.text ?: @""];
        });
    });
}

- (void)applyFilter:(NSString *)query {
    NSArray<NSString *> *tokens = [[query lowercaseString]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<WAGRABPropEntry *> *filtered = self.allEntries;
    if (query.length) {
        filtered = [filtered filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WAGRABPropEntry *entry, __unused NSDictionary *bindings) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                entry.className ?: @"", entry.selectorName ?: @"",
                entry.typeName ?: @"", entry.classMethod ? @"class" : @"instance"].lowercaseString;
            for (NSString *token in tokens) {
                if (token.length && ![haystack containsString:token]) return NO;
            }
            return YES;
        }]];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in filtered) {
        NSString *key = entry.className.length ? entry.className : @"Other";
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:entry];
    }
    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups;

    NSUInteger editable = 0;
    NSUInteger active = 0;
    for (WAGRABPropEntry *entry in filtered) {
        if (!WAGRRuntimeValueTypeIsObject(entry.typeCode)) editable++;
        if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) active++;
    }
    self.title = [NSString stringWithFormat:@"AB Props (%lu · %lu editáveis%@)",
                  (unsigned long)filtered.count,
                  (unsigned long)editable,
                  active ? [NSString stringWithFormat:@" · %lu ON", (unsigned long)active] : @""];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
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
    return [NSString stringWithFormat:@"%@ (%lu)", key, (unsigned long)self.sections[key].count];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"BOOL, inteiros, float/double e objetos Foundation aceitam override tipado. "
            "Objeto customizado permanece protegido até existir hook da classe concreta. "
            "Toque para editar; pressão longa abre as mesmas ações.";
}

- (WAGRABPropEntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRABPropsRuntimeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

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
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod);

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@", entry.classMethod ? @"+ " : @"- ", entry.selectorName];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\nAtual: %@%@",
        entry.className, entry.typeName ?: @"?", current ?: @"?",
        overridden ? [NSString stringWithFormat:@" · FORCE %@", forced == NSNull.null ? @"nil" : forced] : @""];
    cell.detailTextLabel.textColor = overridden ? UIColor.systemCyanColor : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:@selector(boolSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRABSwitchEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    UILongPressGestureRecognizer *longPress = objc_getAssociatedObject(cell, kWAGRABLongPressKey);
    if (!longPress) {
        longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
        longPress.minimumPressDuration = 0.45;
        [cell addGestureRecognizer:longPress];
        objc_setAssociatedObject(cell, kWAGRABLongPressKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)boolSwitchChanged:(UISwitch *)sender {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRABSwitchEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName, entry.classMethod, entry.typeCode, @(sender.isOn));
    (void)WAGRRuntimeValueInstallHook(entry.className, entry.selectorName, entry.classMethod, entry.typeCode);
    [self applyFilter:self.searchController.searchBar.text ?: @""];
}

- (void)presentEditorForEntry:(WAGRABPropEntry *)entry fromView:(UIView *)sourceView {
    if (!entry) return;
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
    __weak typeof(self) weakSelf = self;
    WAGRPresentRuntimeValueEditor(self, sourceView,
        entry.className, entry.selectorName, entry.classMethod, entry.typeCode,
        current, raw, ^{
            [weakSelf applyFilter:weakSelf.searchController.searchBar.text ?: @""];
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

- (void)showActiveOverrides {
    NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();
    NSString *message = specs.count
        ? [NSString stringWithFormat:@"%lu overrides tipados ativos. Pesquise pelo nome para localizar e editar.", (unsigned long)specs.count]
        : @"Nenhum override tipado ativo.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Overrides ativos" message:message preferredStyle:UIAlertControllerStyleAlert];
    if (specs.count) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Limpar todos" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            for (NSDictionary *spec in specs) {
                WAGRRuntimeValueClearOverride(spec[@"class"], spec[@"selector"], [spec[@"meta"] boolValue]);
            }
            [self applyFilter:self.searchController.searchBar.text ?: @""];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
