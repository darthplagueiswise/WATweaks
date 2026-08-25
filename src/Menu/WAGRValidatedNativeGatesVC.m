#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../WAPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "WAGRMenuTheme.h"

extern BOOL WAGRGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern void WAGRDogfoodEnsureHooksInstalled(void);

typedef NS_ENUM(NSInteger, WAGRValidatedBundleKind) {
    WAGRValidatedBundleEmployee = 0,
    WAGRValidatedBundleSwizzle = 1,
};

@interface WAGRValidatedGate : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *className;
@property(nonatomic, assign) BOOL classMethod;
@property(nonatomic, assign) NSUInteger stableID;
@property(nonatomic, copy) NSString *note;
@property(nonatomic, assign) BOOL desiredValue;
@end
@implementation WAGRValidatedGate @end

static WAGRValidatedGate *WAGRVGate(NSString *title, NSUInteger stableID,
                                    NSString *className, NSString *selectorName,
                                    BOOL classMethod, BOOL desiredValue,
                                    NSString *note) {
    WAGRValidatedGate *gate = [WAGRValidatedGate new];
    gate.title = title ?: selectorName;
    gate.stableID = stableID;
    gate.className = className ?: @"WAABProperties";
    gate.selectorName = selectorName ?: @"";
    gate.classMethod = classMethod;
    gate.desiredValue = desiredValue;
    gate.note = note ?: @"";
    return gate;
}

static NSArray<WAGRValidatedGate *> *WAGRValidatedEmployeeGates(void) {
    static NSArray *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        items = @[
            WAGRVGate(@"Internal user semantic gate", 0, @"WAServerProperties", @"isInternalUser", YES, YES,
                      @"Gate calculado; não é um AB descriptor simples."),
            WAGRVGate(@"Meta employee wrapper", 0, @"WAABProperties", @"isMetaEmployeeOrInternalTester", NO, YES,
                      @"Wrapper semântico; o getter AB confirmado abaixo usa snake_case."),
            WAGRVGate(@"Meta employee / internal tester", 1777, @"WAABProperties", @"is_meta_employee_or_internal_tester", NO, YES, @"AB 1777"),
            WAGRVGate(@"Internal tester", 2945, @"WAABProperties", @"is_internal_tester", NO, YES, @"AB 2945"),
            WAGRVGate(@"MobileConfig debug UI", 23336, @"WAABProperties", @"waios_mc_debug_ui_enabled", NO, YES, @"AB 23336"),
            WAGRVGate(@"Get Help internal bug report", 1664, @"WAABProperties", @"get_help_internal_bug_report_enabled", NO, YES, @"AB 1664"),
            WAGRVGate(@"Internal in-app bug reporting", 2298, @"WAABProperties", @"ios_internal_in_app_bug_reporting_enable", NO, YES, @"AB 2298"),
            WAGRVGate(@"Internal Hall", 6415, @"WAABProperties", @"ios_internal_hall_enabled", NO, YES, @"AB 6415"),
            WAGRVGate(@"Internal rage shake", 9660, @"WAABProperties", @"ios_internal_rage_shake_enabled", NO, YES, @"AB 9660"),
            WAGRVGate(@"HN dogfooding", 13556, @"WAABProperties", @"hn_dogfooding", NO, YES, @"AB 13556"),
            WAGRVGate(@"Malibu dogfooding", 14389, @"WAABProperties", @"malibu_dogfooding", NO, YES, @"AB 14389"),
            WAGRVGate(@"Dogfood settings entrypoint", 22822, @"WAABProperties", @"dogfooding_nudge_settings_entrypoint_enabled", NO, YES, @"AB 22822"),
            WAGRVGate(@"Dogfood home banner", 22843, @"WAABProperties", @"dogfooding_nudge_banner_home_screen_enabled", NO, YES, @"AB 22843"),
            WAGRVGate(@"Internal bug-report bottom sheet", 24285, @"WAABProperties", @"internal_bug_reporting_bottom_sheet", NO, YES, @"AB 24285"),
            WAGRVGate(@"Username dogfood privacy", 24738, @"WAABProperties", @"username_dogfooding_pn_privacy_enabled", NO, YES, @"AB 24738"),
            WAGRVGate(@"Username dogfood periodic conversion", 24740, @"WAABProperties", @"username_dogfooding_pn_privacy_periodic_conversion_enabled", NO, YES, @"AB 24740"),
            WAGRVGate(@"Dogfooder task ID in bug report", 27444, @"WAABProperties", @"give_dogfooders_task_id_for_bug_reporting", NO, YES, @"AB 27444"),
            WAGRVGate(@"Fishfooding toggle in bug report", 33156, @"WAABProperties", @"show_fishfooding_toggle_in_bug_reporting_form", NO, YES, @"AB 33156"),
            WAGRVGate(@"Vault backup internal debug tool", 34577, @"WAABProperties", @"ios_vault_backup_internal_debug_tool_enabled", NO, YES, @"AB 34577"),
        ];
    });
    return items;
}

static NSArray<WAGRValidatedGate *> *WAGRValidatedSwizzleGates(void) {
    static NSArray *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        items = @[
            WAGRVGate(@"TextInputContext method swizzling", 5306, @"WAABProperties", @"enable_method_swizzling_for_textinputcontext", NO, YES, @"AB 5306"),
            WAGRVGate(@"RTIInputSystemServiceSession swizzle", 8570, @"WAABProperties", @"input_system_service_session_swizzle_enabled", NO, YES, @"AB 8570"),
            WAGRVGate(@"Pre-2025 UI assert main-thread swizzles", 14950, @"WAABProperties", @"wa_pre_2025_enable_ui_assert_main_thread_swizzles", NO, YES, @"AB 14950"),
            WAGRVGate(@"UITraitCollection current-trait swizzle", 22476, @"WAABProperties", @"ios_swizzle_uitrait_collection_set_current_trait_collection", NO, YES, @"AB 22476"),
        ];
    });
    return items;
}

static NSString *WAGRBundleKey(WAGRValidatedBundleKind kind) {
    return kind == WAGRValidatedBundleEmployee
        ? @"watweak_validated_employee_internal_bundle"
        : @"watweak_validated_swizzle_bundle";
}

static NSString *WAGRBundleBackupKey(WAGRValidatedBundleKind kind) {
    return [WAGRBundleKey(kind) stringByAppendingString:@".backup"];
}

static NSArray<WAGRValidatedGate *> *WAGRBundleItems(WAGRValidatedBundleKind kind) {
    return kind == WAGRValidatedBundleEmployee ? WAGRValidatedEmployeeGates() : WAGRValidatedSwizzleGates();
}

static void WAGRInstallValidatedGate(WAGRValidatedGate *gate) {
    if (!gate.selectorName.length) return;
    BOOL ok = WAGRGateInstallHookForSelector(gate.className, gate.selectorName, gate.classMethod);
    if (!ok && [gate.className isEqualToString:@"WAABProperties"]) {
        (void)WAGRWAABInstallHooksForAllRuntimeImages();
        (void)WAGRGateInstallHookForSelector(gate.className, gate.selectorName, gate.classMethod);
    }
}

static void WAGRSetValidatedBundle(WAGRValidatedBundleKind kind, BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *backupKey = WAGRBundleBackupKey(kind);
    NSArray<WAGRValidatedGate *> *items = WAGRBundleItems(kind);

    if (enabled) {
        NSMutableDictionary *backup = [NSMutableDictionary dictionary];
        for (WAGRValidatedGate *gate in items) {
            backup[gate.selectorName] = @{
                @"present": @(WAGRGateIsSet(gate.selectorName)),
                @"value": @(WAGRGateIsSet(gate.selectorName) ? WAGRGateGet(gate.selectorName) : NO),
            };
            WAGRGateSet(gate.selectorName, gate.desiredValue);
            WAGRInstallValidatedGate(gate);
        }
        [defaults setObject:backup forKey:backupKey];
        [defaults setBool:YES forKey:WAGRBundleKey(kind)];

        if (kind == WAGRValidatedBundleEmployee) {
            // The old Employee master owns a much broader heuristic gate set.
            // Disable that preference when the binary-validated bundle is chosen
            // so the two policies cannot silently fight each other.
            [defaults setBool:NO forKey:WA_PREF_EMPLOYEE_MASTER];
            WAGRNativeDevMenuEnsureHooksInstalled();
        }
    } else {
        NSDictionary *backup = [defaults objectForKey:backupKey];
        for (WAGRValidatedGate *gate in items) {
            NSDictionary *entry = [backup[gate.selectorName] isKindOfClass:NSDictionary.class] ? backup[gate.selectorName] : nil;
            if ([entry[@"present"] boolValue]) WAGRGateSet(gate.selectorName, [entry[@"value"] boolValue]);
            else WAGRGateClear(gate.selectorName);
        }
        [defaults removeObjectForKey:backupKey];
        [defaults setBool:NO forKey:WAGRBundleKey(kind)];
    }
    [defaults synchronize];
}

@interface WAGRValidatedNativeGatesVC : UITableViewController
@property(nonatomic, assign) WAGRValidatedBundleKind kind;
@property(nonatomic, copy) NSArray<WAGRValidatedGate *> *items;
@end

@implementation WAGRValidatedNativeGatesVC

- (instancetype)initWithKind:(WAGRValidatedBundleKind)kind {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _kind = kind;
    _items = WAGRBundleItems(kind);
    self.title = kind == WAGRValidatedBundleEmployee ? @"Employee / Internal" : @"Swizzle ABProps";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 2; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.items.count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Bundle validado no binário atual";
    return self.kind == WAGRValidatedBundleEmployee ? @"Componentes" : @"ABProps independentes";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    if (self.kind == WAGRValidatedBundleEmployee) {
        return @"Não existe uma única ABProp Employee/Internal/Dogfood. O master desta tela aplica somente os gates listados abaixo, confirmados no SharedModules(4)/WhatsApp(4).";
    }
    return @"O WhatsApp atual não possui uma ABProp global chamada ‘Swizzle’. Este master é apenas um bundle explícito das quatro ABProps de swizzling confirmadas no executable.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRValidatedNativeGate";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMenuApplyCellStyle(cell, indexPath.row, @"validated-gate");
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 3;
    cell.accessoryView = nil;

    UISwitch *toggle = [UISwitch new];
    if (indexPath.section == 0) {
        BOOL on = [NSUserDefaults.standardUserDefaults boolForKey:WAGRBundleKey(self.kind)];
        cell.textLabel.text = self.kind == WAGRValidatedBundleEmployee
            ? @"Validated Employee/Internal bundle" : @"Validated Swizzle bundle";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu componentes binário-validados", (unsigned long)self.items.count];
        toggle.on = on;
        toggle.tag = -1;
    } else {
        WAGRValidatedGate *gate = self.items[(NSUInteger)indexPath.row];
        cell.textLabel.text = gate.title;
        NSString *idText = gate.stableID ? [NSString stringWithFormat:@"AB %lu", (unsigned long)gate.stableID] : @"semantic/runtime gate";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ %@%@\n%@",
            idText, gate.className, gate.classMethod ? @"+" : @"-", gate.selectorName, gate.note ?: @""];
        toggle.on = WAGRGateIsSet(gate.selectorName) ? WAGRGateGet(gate.selectorName) : NO;
        toggle.tag = indexPath.row;
        objc_setAssociatedObject(toggle, @selector(gateChanged:), gate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [toggle addTarget:self action:@selector(gateChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)gateChanged:(UISwitch *)sender {
    if (sender.tag == -1) {
        WAGRSetValidatedBundle(self.kind, sender.isOn);
        [self.tableView reloadData];
        return;
    }
    WAGRValidatedGate *gate = objc_getAssociatedObject(sender, @selector(gateChanged:));
    if (!gate) return;
    WAGRGateSet(gate.selectorName, sender.isOn);
    WAGRInstallValidatedGate(gate);
}

@end

#pragma mark - Main-menu integration without depending on private WATCell headers

static void (*gWAGRValidatedOriginalRebuild)(id, SEL) = NULL;

static id WAGRVKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}
static void WAGRVSetKVC(id object, NSString *key, id value) {
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static id WAGRVNavCell(NSString *title, NSString *subtitle, NSString *icon,
                       void (^tap)(UIViewController *)) {
    Class cls = NSClassFromString(@"WATCell");
    id cell = [cls new];
    if (!cell) return nil;
    WAGRVSetKVC(cell, @"type", @1); // WATCellNav
    WAGRVSetKVC(cell, @"title", title);
    WAGRVSetKVC(cell, @"subtitle", subtitle);
    WAGRVSetKVC(cell, @"icon", icon);
    WAGRVSetKVC(cell, @"onTap", [tap copy]);
    return cell;
}

static void WAGRValidatedRebuildSections(id self, SEL _cmd) {
    if (gWAGRValidatedOriginalRebuild) gWAGRValidatedOriginalRebuild(self, _cmd);
    NSArray *sections = WAGRVKVC(self, @"_sections") ?: WAGRVKVC(self, @"sections");
    if (sections.count < 2) return;
    id dogfood = sections[1];
    NSArray *oldRows = WAGRVKVC(dogfood, @"rows") ?: @[];
    NSMutableArray *rows = [NSMutableArray array];

    id employee = WAGRVNavCell(@"Employee / Internal / Dogfood",
        @"Componentes e AB IDs confirmados no SharedModules(4)/WhatsApp(4)",
        @"person.badge.shield.checkmark.fill", ^(UIViewController *from) {
            [from.navigationController pushViewController:[[WAGRValidatedNativeGatesVC alloc] initWithKind:WAGRValidatedBundleEmployee] animated:YES];
        });
    id swizzle = WAGRVNavCell(@"Swizzle ABProps",
        @"AB 5306 · 8570 · 14950 · 22476 — gates independentes",
        @"arrow.triangle.2.circlepath", ^(UIViewController *from) {
            [from.navigationController pushViewController:[[WAGRValidatedNativeGatesVC alloc] initWithKind:WAGRValidatedBundleSwizzle] animated:YES];
        });
    if (employee) [rows addObject:employee];
    if (swizzle) [rows addObject:swizzle];

    // Keep the native debug-menu row, but remove the old broad Employee master
    // and ambiguous duplicate identity switches from the top-level menu.
    for (id row in oldRows) {
        NSString *title = WAGRVKVC(row, @"title");
        if ([title isEqualToString:@"Debug menu nativo"]) [rows addObject:row];
    }
    WAGRVSetKVC(dogfood, @"rows", rows);
}

static void WAGRInstallValidatedGateMenu(void) {
    Class cls = NSClassFromString(@"WAGRMainSettingsVC");
    SEL selector = NSSelectorFromString(@"rebuildSections");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRValidatedRebuildSections) return;
    gWAGRValidatedOriginalRebuild = (void (*)(id, SEL))current;
    method_setImplementation(method, (IMP)WAGRValidatedRebuildSections);
}

__attribute__((constructor))
static void WAGRValidatedNativeGatesCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRInstallValidatedGateMenu(); });
        });
    }
}
