// WAGRABPropsBrowserVC.m
// Searchable runtime browser for the AB getters that still ship in RC builds.

#import "WAGRABPropsBrowserVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRGateStore.h"
#import <objc/runtime.h>

extern BOOL WAGRGateInstallHookForSelector(NSString *className,
                                           NSString *selectorName,
                                           BOOL isClassMethod);
extern void WAGRGateHooksEnsureInstalled(void);

static const void *kWAGRABSwitchEntryKey = &kWAGRABSwitchEntryKey;
static const void *kWAGRABLongPressKey = &kWAGRABLongPressKey;

@interface WAGRABPropsBrowserVC ()
@property(nonatomic, strong, nullable) id userContext;
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
    self.tableView.estimatedRowHeight = 68.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Buscar AB prop ou classe";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchController = search;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Scan"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(scanNow)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didScan) [self scanNow];
}

- (void)scanNow {
    self.didScan = YES;
    self.title = @"Escaneando AB Props…";
    NSArray *objects = WAGRABPropsResolveRuntimeObjects(self.userContext);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runtimeObjects = objects ?: @[];
            self.allEntries = entries ?: @[];
            [self applyFilter:self.searchController.searchBar.text ?: @""];
        });
    });
}

- (void)applyFilter:(NSString *)query {
    NSString *needle = query.lowercaseString ?: @"";
    NSArray<WAGRABPropEntry *> *filtered = self.allEntries;

    if (needle.length) {
        NSArray<NSString *> *tokens = [needle componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        filtered = [filtered filteredArrayUsingPredicate:[NSPredicate
            predicateWithBlock:^BOOL(WAGRABPropEntry *entry, __unused NSDictionary *bindings) {
                NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
                    entry.className ?: @"",
                    entry.selectorName ?: @"",
                    entry.typeName ?: @""].lowercaseString;
                for (NSString *token in tokens) {
                    if (token.length && ![haystack containsString:token]) return NO;
                }
                return YES;
            }]];
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups =
        [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in filtered) {
        NSString *key = entry.className.length ? entry.className : @"Other";
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:entry];
    }

    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:
        @selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups;

    NSUInteger booleanCount = 0;
    for (WAGRABPropEntry *entry in filtered) {
        if (WAGRABPropEntryIsBoolean(entry)) booleanCount++;
    }
    self.title = [NSString stringWithFormat:@"AB Props (%lu · %lu BOOL)",
                  (unsigned long)filtered.count,
                  (unsigned long)booleanCount];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sectionKeys.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return 0;
    return (NSInteger)self.sections[self.sectionKeys[(NSUInteger)section]].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return nil;
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@ (%lu)",
            key,
            (unsigned long)self.sections[key].count];
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"A build RC removeu apenas o browser nativo. Os getters continuam "
            "carregados. BOOL/char aceita Force YES/NO; int, double e object são "
            "lidos com a ABI correta e permanecem read-only.";
}

- (WAGRABPropEntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)indexPath.section]];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRABPropsRuntimeCell";
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
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    if (!entry) return cell;

    BOOL currentBool = NO;
    BOOL boolKnown = NO;
    NSString *current = WAGRABPropsCurrentValue(entry,
                                                self.runtimeObjects,
                                                &currentBool,
                                                &boolKnown);
    BOOL isBoolean = WAGRABPropEntryIsBoolean(entry);
    BOOL overridden = isBoolean && WAGRGateIsSet(entry.selectorName);
    BOOL displayedBool = overridden ? WAGRGateGet(entry.selectorName) : currentBool;

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@",
                           entry.classMethod ? @"+ " : @"- ",
                           entry.selectorName ?: @"(selector)"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@%@",
        entry.className ?: @"",
        entry.typeName ?: @"?",
        current ?: @"?",
        overridden ? (displayedBool ? @" · FORCE YES" : @" · FORCE NO") : @""];

    if (isBoolean) {
        UISwitch *toggle = (UISwitch *)cell.accessoryView;
        if (![toggle isKindOfClass:UISwitch.class]) {
            toggle = [UISwitch new];
            [toggle addTarget:self
                       action:@selector(boolSwitchChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle,
                                 kWAGRABSwitchEntryKey,
                                 entry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = boolKnown ? displayedBool : (overridden && displayedBool);
        toggle.enabled = boolKnown || overridden;
        toggle.onTintColor = overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor;
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
        objc_setAssociatedObject(cell,
                                 kWAGRABLongPressKey,
                                 longPress,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)boolSwitchChanged:(UISwitch *)sender {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRABSwitchEntryKey);
    if (!entry || !WAGRABPropEntryIsBoolean(entry)) return;

    WAGRGateSet(entry.selectorName, sender.isOn);
    WAGRGateHooksEnsureInstalled();
    WAGRGateInstallHookForSelector(entry.className,
                                   entry.selectorName,
                                   entry.classMethod);
    [self.tableView reloadData];
}

- (void)presentActionsForEntry:(WAGRABPropEntry *)entry
                      fromView:(UIView *)sourceView {
    if (!entry) return;

    BOOL currentBool = NO;
    BOOL boolKnown = NO;
    NSString *current = WAGRABPropsCurrentValue(entry,
                                                self.runtimeObjects,
                                                &currentBool,
                                                &boolKnown);
    NSString *message = [NSString stringWithFormat:@"%@\n%@\nAtual: %@",
                         entry.className ?: @"",
                         entry.typeName ?: @"?",
                         current ?: @"?"];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:entry.selectorName
        message:message
        preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = sourceView ?: self.view;
    sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;

    if (WAGRABPropEntryIsBoolean(entry)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force YES"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                WAGRGateSet(entry.selectorName, YES);
                WAGRGateHooksEnsureInstalled();
                WAGRGateInstallHookForSelector(entry.className,
                                               entry.selectorName,
                                               entry.classMethod);
                [self.tableView reloadData];
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force NO"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                WAGRGateSet(entry.selectorName, NO);
                WAGRGateHooksEnsureInstalled();
                WAGRGateInstallHookForSelector(entry.className,
                                               entry.selectorName,
                                               entry.classMethod);
                [self.tableView reloadData];
            }]];
        if (WAGRGateIsSet(entry.selectorName)) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Usar original"
                style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *action) {
                    WAGRGateClear(entry.selectorName);
                    WAGRGateForgetHook(entry.className,
                                       entry.selectorName,
                                       entry.classMethod);
                    [self.tableView reloadData];
                }]];
        }
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar nome + valor"
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:
                @"%@ %@ %@ = %@",
                entry.classMethod ? @"+" : @"-",
                entry.className ?: @"",
                entry.selectorName ?: @"",
                current ?: @"?"];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
        style:UIAlertActionStyleCancel
        handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self presentActionsForEntry:[self entryAtIndexPath:indexPath]
                        fromView:[tableView cellForRowAtIndexPath:indexPath]];
}

- (void)longPressRow:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)gesture.view;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;
    [self presentActionsForEntry:[self entryAtIndexPath:indexPath]
                        fromView:cell];
}

@end
