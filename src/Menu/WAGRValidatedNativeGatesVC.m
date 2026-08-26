#import "WAGRValidatedNativeGatesVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRFeatureState.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

extern void WAGRDogfoodEnsureHooksInstalled(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);

static const void *kWAGREmployeeGateKey = &kWAGREmployeeGateKey;

@interface WAGREmployeeGate : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSArray<NSDictionary *> *targets;
@property(nonatomic, assign) NSUInteger stableID;
@property(nonatomic, assign) BOOL desiredValue;
@property(nonatomic, copy) NSString *note;
@end
@implementation WAGREmployeeGate @end

static WAGREmployeeGate *WAGREmployeeItem(NSString *title,
                                          NSUInteger stableID,
                                          NSString *selectorName,
                                          NSArray<NSDictionary *> *targets,
                                          BOOL desiredValue,
                                          NSString *note) {
    WAGREmployeeGate *item = [WAGREmployeeGate new];
    item.title = title ?: selectorName ?: @"Gate";
    item.stableID = stableID;
    item.selectorName = selectorName ?: @"";
    item.targets = targets.count ? targets : WAGRFeatureDefaultWAABTargets();
    item.desiredValue = desiredValue;
    item.note = note ?: @"";
    return item;
}

static NSArray<WAGREmployeeGate *> *WAGREmployeeItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *waab = WAGRFeatureDefaultWAABTargets();
        items = @[
            WAGREmployeeItem(@"Internal user semantic gate", 0, @"isInternalUser",
                @[WAGRFeatureTarget(@"WAServerProperties", YES)], YES,
                @"Gate calculado; não é um AB descriptor simples."),
            WAGREmployeeItem(@"Meta employee wrapper", 0, @"isMetaEmployeeOrInternalTester",
                @[WAGRFeatureTarget(@"WAABProperties", NO)], YES,
                @"Wrapper semântico sobre o estado employee/internal."),
            WAGREmployeeItem(@"Meta employee / internal tester", 1777, @"is_meta_employee_or_internal_tester", waab, YES, @""),
            WAGREmployeeItem(@"Internal tester", 2945, @"is_internal_tester", waab, YES, @""),
            WAGREmployeeItem(@"MobileConfig debug UI", 23336, @"waios_mc_debug_ui_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Get Help internal bug report", 1664, @"get_help_internal_bug_report_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Internal in-app bug reporting", 2298, @"ios_internal_in_app_bug_reporting_enable", waab, YES, @""),
            WAGREmployeeItem(@"Internal Hall", 6415, @"ios_internal_hall_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Internal rage shake", 9660, @"ios_internal_rage_shake_enabled", waab, YES, @""),
            WAGREmployeeItem(@"HN dogfooding", 13556, @"hn_dogfooding", waab, YES, @""),
            WAGREmployeeItem(@"Malibu dogfooding", 14389, @"malibu_dogfooding", waab, YES, @""),
            WAGREmployeeItem(@"Dogfood settings entrypoint", 22822, @"dogfooding_nudge_settings_entrypoint_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Dogfood home banner", 22843, @"dogfooding_nudge_banner_home_screen_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Internal bug-report bottom sheet", 24285, @"internal_bug_reporting_bottom_sheet", waab, YES, @""),
            WAGREmployeeItem(@"Username dogfood privacy", 24738, @"username_dogfooding_pn_privacy_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Username dogfood periodic conversion", 24740, @"username_dogfooding_pn_privacy_periodic_conversion_enabled", waab, YES, @""),
            WAGREmployeeItem(@"Dogfooder task ID in bug report", 27444, @"give_dogfooders_task_id_for_bug_reporting", waab, YES, @""),
            WAGREmployeeItem(@"Fishfooding toggle in bug report", 33156, @"show_fishfooding_toggle_in_bug_reporting_form", waab, YES, @""),
            WAGREmployeeItem(@"Vault backup internal debug tool", 34577, @"ios_vault_backup_internal_debug_tool_enabled", waab, YES, @""),
        ];
    });
    return items;
}

static NSString *WAGRStateSourceName(WAGRFeatureStateSource source) {
    switch (source) {
        case WAGRFeatureStateSourceOverride: return @"override";
        case WAGRFeatureStateSourceOriginal: return @"runtime original";
        case WAGRFeatureStateSourceNativeCache: return @"cache gabp";
        case WAGRFeatureStateSourceUnavailable: return @"indisponível";
    }
    return @"indisponível";
}

@interface WAGRValidatedNativeGatesVC ()
@property(nonatomic, copy) NSArray<WAGREmployeeGate *> *items;
@end

@implementation WAGRValidatedNativeGatesVC

- (instancetype)initEmployeeInternalDogfood {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _items = WAGREmployeeItems();
    self.title = @"Employee / Internal";
    return self;
}

- (instancetype)init {
    return [self initEmployeeInternalDogfood];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 88.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone
        target:self action:@selector(applyNow)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 2; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.items.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Bundle efetivo" : @"Componentes";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return @"Não existe uma única ABProp Employee/Internal/Dogfood. Este master não possui storage próprio: ele é calculado a partir dos componentes abaixo e escreve exatamente no mesmo RuntimeValueStore usado pelo ABProperties Browser.";
}

- (BOOL)masterIsOn {
    for (WAGREmployeeGate *item in self.items) {
        BOOL value = NO;
        if (!WAGRFeatureReadBool(item.selectorName, item.targets, item.stableID, &value, NULL) ||
            value != item.desiredValue) return NO;
    }
    return self.items.count > 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGREmployeeCanonicalGate";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMenuApplyCellStyle(cell, indexPath.row, @"employee-internal");
    cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;

    UISwitch *toggle = [UISwitch new];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        cell.textLabel.text = @"★ Internal / Employee / Dogfood";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Estado derivado dos %lu componentes; sem master paralelo.",
            (unsigned long)self.items.count];
        toggle.on = [self masterIsOn];
        toggle.tag = -1;
        [toggle addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    WAGREmployeeGate *item = self.items[(NSUInteger)indexPath.row];
    BOOL value = NO;
    WAGRFeatureStateSource source = WAGRFeatureStateSourceUnavailable;
    BOOL available = WAGRFeatureReadBool(item.selectorName, item.targets, item.stableID, &value, &source);
    NSUInteger resolvedID = WAGRFeatureResolvedABID(item.selectorName, item.stableID);

    cell.textLabel.text = item.selectorName.length ? item.selectorName : item.title;
    NSMutableString *detail = [NSMutableString string];
    if (resolvedID) [detail appendFormat:@"AB %lu · ", (unsigned long)resolvedID];
    else [detail appendString:@"semantic gate · "];
    [detail appendFormat:@"%@ · %@", item.title, WAGRStateSourceName(source)];
    if (item.note.length) [detail appendFormat:@"\n%@", item.note];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = source == WAGRFeatureStateSourceOverride
        ? UIColor.systemBlueColor : WAGRMenuSecondaryTextColor();
    toggle.on = available ? value : NO;
    toggle.enabled = available || item.targets.count > 0;
    objc_setAssociatedObject(toggle, kWAGREmployeeGateKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [toggle addTarget:self action:@selector(componentChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)componentChanged:(UISwitch *)sender {
    WAGREmployeeGate *item = objc_getAssociatedObject(sender, kWAGREmployeeGateKey);
    if (!item) return;
    (void)WAGRFeatureSetBool(item.selectorName, item.targets, sender.isOn);
    WAGRDogfoodEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    [self.tableView reloadData];
}

- (void)masterChanged:(UISwitch *)sender {
    for (WAGREmployeeGate *item in self.items) {
        BOOL value = sender.isOn ? item.desiredValue : !item.desiredValue;
        (void)WAGRFeatureSetBool(item.selectorName, item.targets, value);
    }
    WAGRDogfoodEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    [self.tableView reloadData];
}

- (void)applyNow {
    NSUInteger reapplied = WAGRRuntimeValueReinstallPersistedHooks();
    WAGRDogfoodEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Employee / Internal"
        message:[NSString stringWithFormat:@"%lu RuntimeValue hooks persistidos reaplicados. O estado desta tela continua sendo o mesmo do ABProperties Browser.", (unsigned long)reapplied]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
