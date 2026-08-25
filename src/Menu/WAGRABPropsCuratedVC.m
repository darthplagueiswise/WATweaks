#import "WAGRABPropsCuratedVC.h"
#import "WAGRMenuTheme.h"
#import "WAGRRuntimeValueEditor.h"
#import "WAGRRuntimeJSONEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsCodeResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import <objc/runtime.h>

extern id WAGRCurrentUserContext(void);

static const void *kWAGRCuratedEntryKey = &kWAGRCuratedEntryKey;

typedef NS_ENUM(NSInteger, WAGRCuratedSectionKind) {
    WAGRCuratedSectionMaster = 0,
    WAGRCuratedSectionValues = 1,
};

@interface WAGRABPropsCuratedVC () <UISearchBarDelegate>
@property(nonatomic, assign) WAGRABCuratedMode mode;
@property(nonatomic, strong) NSArray *runtimeObjects;
@property(nonatomic, strong) NSArray<WAGRABPropEntry *> *allCurated;
@property(nonatomic, strong) NSArray<NSString *> *sectionKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<WAGRABPropEntry *> *> *sections;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) BOOL scanned;
@end

@implementation WAGRABPropsCuratedVC

- (instancetype)initWithMode:(WAGRABCuratedMode)mode {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _mode = mode;
    _runtimeObjects = @[];
    _allCurated = @[];
    _sectionKeys = @[];
    _sections = @{};
    switch (mode) {
        case WAGRABCuratedModeAura: self.title = @"Aura"; break;
        case WAGRABCuratedModeLiquidGlass: self.title = @"Liquid Glass"; break;
        default: self.title = @"Employee / Internal / Dogfood"; break;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = 62.0;
    self.tableView.estimatedRowHeight = 62.0;
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 4.0;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.placeholder = @"Buscar nome ou AB ID";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.search = search;
    WAGRMenuApplySearchGlass(search.searchBar);

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(scanNow)];

    UIRefreshControl *pull = [UIRefreshControl new];
    [pull addTarget:self action:@selector(scanNow) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;
    [self scanNow];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Values are intentionally not cached separately: rows re-read the same
    // WAGRRuntimeValueStore used by the full ABProps Browser.
    if (self.scanned) [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRMenuApplySearchGlass(self.search.searchBar);
}

static NSInteger WAGRCuratedPreferenceRank(WAGRABPropEntry *entry) {
    NSString *name = entry.className ?: @"";
    if ([name isEqualToString:@"WAABProperties"]) return 0;
    if ([name containsString:@"WAABProperties"]) return 1;
    if ([name containsString:@"FOAWAABProperties"]) return 2;
    return 3;
}

static BOOL WAGRCuratedEmployeeMatch(NSString *name) {
    if (!name.length) return NO;
    NSArray<NSString *> *terms = @[
        @"employee", @"internal", @"dogfood", @"fishfood", @"tester",
        @"rage_shake", @"rageshake", @"bug_report", @"bugreport",
        @"whatsbroken", @"testflight", @"debug_ui", @"debug_menu",
        @"private_abprop", @"private_experiment", @"developer"
    ];
    for (NSString *term in terms) if ([name containsString:term]) return YES;
    return NO;
}

- (BOOL)entryMatchesMode:(WAGRABPropEntry *)entry {
    NSString *name = entry.selectorName.lowercaseString ?: @"";
    // Swizzle ABProps remain searchable in the full AB browser; there is no
    // curated/master Swizzle product surface.
    if ([name containsString:@"swizzle"]) return NO;
    switch (self.mode) {
        case WAGRABCuratedModeAura:
            return [name containsString:@"aura"];
        case WAGRABCuratedModeLiquidGlass:
            return [name containsString:@"liquid_glass"] || [name containsString:@"liquidglass"];
        case WAGRABCuratedModeEmployeeInternalDogfood:
        default:
            return WAGRCuratedEmployeeMatch(name);
    }
}

- (NSString *)semanticSectionForEntry:(WAGRABPropEntry *)entry {
    NSString *name = entry.selectorName.lowercaseString ?: @"";
    if (self.mode == WAGRABCuratedModeAura) {
        return entry.categoryName.length ? entry.categoryName : @"Aura";
    }
    if (self.mode == WAGRABCuratedModeLiquidGlass) {
        return entry.categoryName.length ? entry.categoryName : @"Liquid Glass";
    }
    if ([name containsString:@"rage_shake"] || [name containsString:@"rageshake"]) return @"Rage Shake";
    if ([name containsString:@"bug_report"] || [name containsString:@"bugreport"]) return @"Bug Reporting";
    if ([name containsString:@"dogfood"] || [name containsString:@"fishfood"]) return @"Dogfood / Fishfood";
    if ([name containsString:@"employee"] || [name containsString:@"tester"] ||
        [name containsString:@"internal"]) return @"Employee / Internal";
    if ([name containsString:@"debug"] || [name containsString:@"whatsbroken"] ||
        [name containsString:@"testflight"]) return @"Debug / Tools";
    if ([name containsString:@"private_"] || [name containsString:@"developer"]) return @"Private / Developer";
    return @"Outros relacionados";
}

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    id context = WAGRCurrentUserContext();
    WAGRABCuratedMode mode = self.mode;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = WAGRABPropsResolveRuntimeObjects(context);
        NSArray<WAGRABPropEntry *> *all = WAGRABPropsScan(objects);
        NSMutableDictionary<NSString *, WAGRABPropEntry *> *best = [NSMutableDictionary dictionary];
        for (WAGRABPropEntry *entry in all) {
            // Curated pages are views over real AB descriptor getters only.
            // This deliberately excludes semantic wrappers such as
            // isMetaEmployeeOrInternalTester that do not own a numeric AB ID.
            NSString *code = WAGRABPropsCodeForEntry(entry);
            if (!code.length) continue;
            BOOL matches = NO;
            NSString *lower = entry.selectorName.lowercaseString ?: @"";
            if ([lower containsString:@"swizzle"]) matches = NO;
            else if (mode == WAGRABCuratedModeAura) matches = [lower containsString:@"aura"];
            else if (mode == WAGRABCuratedModeLiquidGlass)
                matches = [lower containsString:@"liquid_glass"] || [lower containsString:@"liquidglass"];
            else matches = WAGRCuratedEmployeeMatch(lower);
            if (!matches) continue;

            NSString *key = entry.selectorName ?: code;
            WAGRABPropEntry *existing = best[key];
            if (!existing || WAGRCuratedPreferenceRank(entry) < WAGRCuratedPreferenceRank(existing)) {
                best[key] = entry;
            }
        }
        NSArray *curated = [best.allValues sortedArrayUsingComparator:^NSComparisonResult(WAGRABPropEntry *a, WAGRABPropEntry *b) {
            return [a.selectorName localizedCaseInsensitiveCompare:b.selectorName];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.scanned = YES;
            self.navigationItem.rightBarButtonItem.enabled = YES;
            [self.refreshControl endRefreshing];
            self.runtimeObjects = objects ?: @[];
            self.allCurated = curated ?: @[];
            [self applyFilter];
        });
    });
}

- (void)applyFilter {
    NSString *query = self.search.searchBar.text.lowercaseString ?: @"";
    NSArray *tokens = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *groups = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in self.allCurated) {
        NSString *code = WAGRABPropsCodeForEntry(entry) ?: @"";
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
            entry.selectorName ?: @"", code, entry.className ?: @"", entry.categoryName ?: @""].lowercaseString;
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (token.length && ![haystack containsString:token]) { matches = NO; break; }
        }
        if (!matches) continue;
        NSString *section = [self semanticSectionForEntry:entry];
        if (!groups[section]) groups[section] = [NSMutableArray array];
        [groups[section] addObject:entry];
    }
    NSArray *preferred = @[@"Employee / Internal", @"Dogfood / Fishfood", @"Rage Shake",
                           @"Bug Reporting", @"Debug / Tools", @"Private / Developer",
                           @"Outros relacionados"];
    self.sectionKeys = [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger ia = [preferred indexOfObject:a], ib = [preferred indexOfObject:b];
        if (ia != NSNotFound || ib != NSNotFound) {
            if (ia == NSNotFound) return NSOrderedDescending;
            if (ib == NSNotFound) return NSOrderedAscending;
            if (ia < ib) return NSOrderedAscending;
            if (ia > ib) return NSOrderedDescending;
        }
        return [a localizedCaseInsensitiveCompare:b];
    }];
    self.sections = groups;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController {
    [self applyFilter];
}

- (BOOL)masterEffectiveOn {
    NSUInteger count = 0;
    for (WAGRABPropEntry *entry in self.allCurated) {
        if (!WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) continue;
        count++;
        id raw = nil;
        BOOL on = NO;
        if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) {
            on = [WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod) boolValue];
        } else {
            (void)WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
            on = [raw respondsToSelector:@selector(boolValue)] && [raw boolValue];
        }
        if (!on) return NO;
    }
    return count > 0;
}

- (void)masterChanged:(UISwitch *)sender {
    BOOL on = sender.isOn;
    NSUInteger changed = 0, failed = 0;
    for (WAGRABPropEntry *entry in self.allCurated) {
        if (!WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) continue;
        if (on) {
            WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                        entry.classMethod, entry.typeCode, @YES);
            if (!WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                             entry.classMethod, entry.typeCode)) failed++;
            changed++;
        } else if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) {
            WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.classMethod);
            changed++;
        }
    }
    if (failed) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Overrides persistidos"
            message:[NSString stringWithFormat:@"%lu ABProps foram marcadas ON; %lu hooks não puderam ser instalados imediatamente e serão tentados novamente por Aplicar/restart.",
                     (unsigned long)changed, (unsigned long)failed]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return self.sectionKeys.count + 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == WAGRCuratedSectionMaster) return 1;
    NSInteger index = section - 1;
    if (index < 0 || index >= (NSInteger)self.sectionKeys.count) return 0;
    return self.sections[self.sectionKeys[(NSUInteger)index]].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Mesmo RuntimeValueStore do ABProps Browser";
    NSInteger index = section - 1;
    if (index < 0 || index >= (NSInteger)self.sectionKeys.count) return nil;
    return self.sectionKeys[(NSUInteger)index];
}

- (WAGRABPropEntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return nil;
    NSInteger index = indexPath.section - 1;
    if (index < 0 || index >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)index]];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString *masterID = @"WAGRCuratedMaster";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:masterID];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:masterID];
        WAGRMenuApplyCellStyle(cell, 0, @"master");
        cell.textLabel.text = @"Forçar todas as ABProps BOOL ON";
        cell.detailTextLabel.text = @"OFF remove só os overrides desta categoria; não força o valor nativo para NO.";
        cell.textLabel.numberOfLines = 1;
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.minimumScaleFactor = 0.62;
        cell.detailTextLabel.numberOfLines = 2;
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self masterEffectiveOn];
        toggle.onTintColor = UIColor.systemBlueColor;
        [toggle addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    static NSString *reuse = @"WAGRCuratedABRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGRABPropEntry *entry = [self entryAtIndexPath:indexPath];
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"ab");
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByClipping;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.48;
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textLabel.textColor = WAGRMenuTextColor();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!entry) return cell;

    NSString *code = WAGRABPropsCodeForEntry(entry) ?: @"?";
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw) ?: @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
    id forced = overridden ? WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod) : nil;
    id effective = overridden ? forced : raw;
    NSString *type = WAGRRuntimeValueTypeName(entry.typeCode) ?: entry.typeName ?: @"?";

    cell.textLabel.text = entry.selectorName;
    NSString *valueText = effective ? [effective description] : current;
    valueText = [valueText stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (valueText.length > 44) valueText = [[valueText substringToIndex:44] stringByAppendingString:@"…"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"AB %@ · %@ · %@%@",
        code, valueText ?: @"?", type, overridden ? @" · override" : @""];
    cell.detailTextLabel.textColor = overridden ? UIColor.systemBlueColor : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [UISwitch new];
        toggle.on = [effective respondsToSelector:@selector(boolValue)] ? [effective boolValue] : NO;
        toggle.onTintColor = overridden ? UIColor.systemBlueColor : UIColor.systemGreenColor;
        objc_setAssociatedObject(toggle, kWAGRCuratedEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(rowSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)rowSwitchChanged:(UISwitch *)sender {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRCuratedEntryKey);
    if (!entry) return;
    BOOL requested = sender.isOn;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, @(requested));
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.classMethod, entry.typeCode);
    if (!installed) {
        // Keep the exact same persistence semantics across both curated and full
        // AB browsers: the override remains stored and Apply/restart can retry.
        sender.onTintColor = UIColor.systemOrangeColor;
    }
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGRABPropEntry *entry = [self entryAtIndexPath:indexPath];
    if (!entry) return;
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, self.runtimeObjects, &raw);
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
    id effective = overridden ? WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod) : raw;
    __weak typeof(self) weakSelf = self;
    if (WAGRRuntimeValueLooksLikeJSON(effective)) {
        WAGRPresentRuntimeJSONEditor(self, entry.selectorName,
            entry.className, entry.selectorName, entry.classMethod, entry.typeCode,
            effective, ^{ [weakSelf.tableView reloadData]; });
    } else {
        WAGRPresentRuntimeValueEditor(self, [tableView cellForRowAtIndexPath:indexPath],
            entry.className, entry.selectorName, entry.classMethod, entry.typeCode,
            current, raw, ^{ [weakSelf.tableView reloadData]; });
    }
}

@end
