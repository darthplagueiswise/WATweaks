#import "WAGRFeatureBundlesVC.h"
#import "WAGRMenuTheme.h"
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

typedef NS_ENUM(NSInteger, WAGRFeatureBundleKind) {
    WAGRFeatureBundleInternal = 0,
    WAGRFeatureBundleLiquidGlass,
    WAGRFeatureBundleAura,
};

static NSString * const kWAGRFeatureSelector = @"selector";
static NSString * const kWAGRFeatureSubtitle = @"subtitle";
static NSString * const kWAGRFeatureClass = @"class";
static NSString * const kWAGRFeatureMeta = @"meta";
static NSString * const kWAGRFeatureDesired = @"desired";

extern void WAGRDogfoodEnsureHooksInstalled(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRAuraEnsureNavigationHooksInstalled(void);
extern void WAGRLGPrefsDidChange(void);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);
extern NSUInteger WAGRReinstallPersistedHooks(void);

static NSDictionary *WAGRFeatureItem(NSString *selector,
                                     NSString *subtitle,
                                     NSString *className,
                                     BOOL meta,
                                     BOOL desired) {
    return @{
        kWAGRFeatureSelector: selector ?: @"",
        kWAGRFeatureSubtitle: subtitle ?: @"",
        kWAGRFeatureClass: className ?: @"WAABProperties",
        kWAGRFeatureMeta: @(meta),
        kWAGRFeatureDesired: @(desired),
    };
}

static NSDictionary *WAGRWAAB(NSString *selector, NSString *subtitle) {
    return WAGRFeatureItem(selector, subtitle, @"WAABProperties", NO, YES);
}

static NSDictionary *WAGRWAABNegative(NSString *selector, NSString *subtitle) {
    return WAGRFeatureItem(selector, subtitle, @"WAABProperties", NO, NO);
}

static NSArray<NSDictionary *> *WAGRInternalFeatureItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        items = @[
            WAGRFeatureItem(@"isInternalUser", @"Gate semântico WAServerProperties", @"WAServerProperties", YES, YES),
            WAGRFeatureItem(@"isMetaEmployeeOrInternalTester", @"Gate employee/internal", @"WAABProperties", NO, YES),
            WAGRWAAB(@"is_meta_employee_or_internal_tester", @"Employee/internal tester · AB 1777"),
            WAGRWAAB(@"is_internal_tester", @"Internal tester · AB 2945"),
            WAGRWAAB(@"waios_mc_debug_ui_enabled", @"MobileConfig debug UI · AB 23336"),
            WAGRWAAB(@"whatsbroken_enabled", @"What's Broken / internal diagnostics · AB 24907"),
            WAGRWAAB(@"private_experimentation_should_sync", @"Private Experimentation sync · AB 23727"),
            WAGRWAAB(@"private_abprop_for_dev_only", @"Private ABProp developer gate"),
            WAGRWAAB(@"private_experimentation_use_acs_config_id", @"Private Experimentation ACS config"),
            WAGRWAAB(@"dogfooding_nudge_settings_entrypoint_enabled", @"Dogfood settings entrypoint · AB 22822"),
            WAGRWAAB(@"dogfooding_nudge_banner_home_screen_enabled", @"Dogfood home banner · AB 22843"),
            WAGRWAAB(@"username_dogfooding_pn_privacy_enabled", @"Username dogfood privacy · AB 24738"),
            WAGRWAAB(@"username_dogfooding_pn_privacy_periodic_conversion_enabled", @"Username dogfood periodic conversion · AB 24740"),
            WAGRWAAB(@"tbv_pass_eligibility_dogfooding_gk", @"TBV dogfood eligibility"),
            WAGRWAAB(@"get_help_internal_bug_report_enabled", @"Internal bug report entrypoint · AB 1664"),
            WAGRWAAB(@"ios_internal_in_app_bug_reporting_enable", @"In-app internal bug reporting · AB 2298"),
            WAGRWAAB(@"ios_internal_rage_shake_enabled", @"Internal rage shake · AB 9660"),
            WAGRWAAB(@"internal_bug_reporting_bottom_sheet", @"Internal bug-report bottom sheet · AB 24285"),
            WAGRWAAB(@"give_dogfooders_task_id_for_bug_reporting", @"Dogfooder task ID in bug reports · AB 27444"),
            WAGRWAAB(@"show_fishfooding_toggle_in_bug_reporting_form", @"Fishfood toggle in bug report · AB 33156"),
            WAGRWAAB(@"groups_member_recommendations_debug_ui", @"Groups recommendations debug UI · AB 8992"),
            WAGRWAAB(@"hn_dogfooding", @"HN dogfood · AB 13556"),
            WAGRWAAB(@"malibu_dogfooding", @"Malibu dogfood · AB 14389"),
            WAGRWAAB(@"bug_reporting_settings_entrypoint_enabled", @"Bug-report settings entrypoint"),
            WAGRWAAB(@"ios_internal_hall_enabled", @"Internal Hall"),
            WAGRWAAB(@"internal_group_indicator", @"Internal group indicator"),
            WAGRWAABNegative(@"graphQLEmployeeC1Disabled", @"Negative gate: employee GraphQL disabled"),
            WAGRWAABNegative(@"ios_contact_suggestions_internal_tool_exclude_employees_enabled", @"Negative gate: exclude employees from internal tool"),
        ];
    });
    return items;
}

static NSArray<NSDictionary *> *WAGRLiquidGlassFeatureItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        items = @[
            WAGRWAAB(@"ios_liquid_glass_enabled", @"Primary Liquid Glass · AB 18023"),
            WAGRWAAB(@"ios_liquid_glass_launched", @"Launch / rollout marker"),
            WAGRWAAB(@"ios_liquid_glass_m1", @"Milestone M1 · AB 18024"),
            WAGRWAAB(@"ios_liquid_glass_m_1_5", @"Milestone M1.5 · AB 19884"),
            WAGRWAAB(@"ios_liquid_glass_m_1_5_context_menu", @"M1.5 context menu"),
            WAGRWAAB(@"ios_liquid_glass_media_m0", @"Media M0"),
            WAGRWAAB(@"ios_liquid_glass_larger_composer", @"Larger composer"),
            WAGRWAAB(@"ios_liquid_glass_media_editor_enabled", @"Media editor"),
            WAGRWAAB(@"ios_liquid_glass_calling_improvement_enabled", @"Calling improvements"),
            WAGRWAAB(@"ios_liquid_glass_workaround_attachment_tray", @"Attachment tray workaround"),
            WAGRWAAB(@"ios_liquid_glass_enable_new_chatbar_ux", @"New chatbar UX · AB 25299"),
            WAGRWAAB(@"ios_liquid_glass_chat_top_bar_m2_enabled", @"Chat top bar M2"),
            WAGRWAAB(@"ios_liquid_glass_text_layout_m2_enabled", @"Text layout M2"),
            WAGRWAAB(@"ios_liquid_glass_m_2_action_tile", @"M2 action tile"),
            WAGRWAAB(@"ios_liquid_glass_unify_ui_refresh_enabled", @"Unified UI refresh"),
            WAGRWAAB(@"ios_liquid_glass_unify_navigation_bar_enabled", @"Unified navigation bar"),
            WAGRWAAB(@"ios_liquid_glass_native_sidebar_enabled", @"Native sidebar"),
            WAGRWAAB(@"status_viewer_redesign_enabled", @"Status viewer redesign"),
        ];
    });
    return items;
}

static NSArray<NSDictionary *> *WAGRAuraFeatureItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        items = @[
            WAGRWAAB(@"aura_enabled", @"Primary Aura gate"),
            WAGRWAAB(@"aura_subscription_simulation_enabled", @"Subscription simulation"),
            WAGRWAAB(@"aura_logging_enabled", @"Aura logging"),
            WAGRWAAB(@"aura_settings_row_enabled", @"Settings entrypoint"),
            WAGRWAAB(@"aura_app_icon_enabled", @"Custom app icons"),
            WAGRWAAB(@"aura_app_icon_benefit_active", @"App-icon benefit active"),
            WAGRWAAB(@"aura_app_icon_multi_account_support", @"App-icon multi-account support"),
            WAGRWAAB(@"aura_app_themes_enabled", @"App themes"),
            WAGRWAAB(@"aura_app_themes_benefit_active", @"Themes benefit active"),
            WAGRWAAB(@"aura_app_themes_illustration_lottie_enabled", @"Theme illustration Lottie"),
            WAGRWAAB(@"aura_app_themes_new_selection_flow_enabled", @"New theme selection flow"),
            WAGRWAAB(@"aura_app_themes_status_ring_enabled", @"Themed status ring"),
            WAGRWAAB(@"aura_app_themes_chat_checkmark_themed_enabled", @"Themed chat checkmark"),
            WAGRWAAB(@"aura_ringtones_enabled", @"Custom ringtones"),
            WAGRWAAB(@"aura_ringtones_benefit_active", @"Ringtones benefit active"),
            WAGRWAAB(@"aura_ringtones_per_chat_enabled", @"Per-chat ringtones"),
            WAGRWAAB(@"aura_pinned_chats_enabled", @"Extended pinned chats"),
            WAGRWAAB(@"aura_pinned_chats_benefit_active", @"Pinned chats benefit active"),
            WAGRWAAB(@"aura_enhanced_lists_enabled", @"Enhanced lists"),
            WAGRWAAB(@"aura_enhanced_lists_benefit_active", @"Enhanced lists benefit active"),
            WAGRWAAB(@"aura_stickers_enabled", @"Premium stickers"),
            WAGRWAAB(@"aura_stickers_benefit_active", @"Stickers benefit active"),
            WAGRWAAB(@"aura_vault_backups_enabled", @"Vault backups"),
            WAGRWAAB(@"aura_vault_backups_benefit_active", @"Vault-backups benefit active"),
            WAGRWAAB(@"aura_custom_reactions_enabled", @"Custom reactions"),
            WAGRWAAB(@"aura_custom_reactions_benefit_active", @"Custom-reactions benefit active"),
            WAGRWAAB(@"aura_exclusive_stickers_in_free_packs_enabled", @"Exclusive stickers in free packs"),
            WAGRWAABNegative(@"aura_kill_switch", @"Negative gate: Aura kill switch"),
        ];
    });
    return items;
}

static NSArray<NSDictionary *> *WAGRFeatureItemsForKind(WAGRFeatureBundleKind kind) {
    switch (kind) {
        case WAGRFeatureBundleInternal: return WAGRInternalFeatureItems();
        case WAGRFeatureBundleLiquidGlass: return WAGRLiquidGlassFeatureItems();
        case WAGRFeatureBundleAura: return WAGRAuraFeatureItems();
    }
    return @[];
}

static NSString *WAGRFeatureTitleForKind(WAGRFeatureBundleKind kind) {
    switch (kind) {
        case WAGRFeatureBundleInternal: return @"Internal / Employee / Dogfood";
        case WAGRFeatureBundleLiquidGlass: return @"Liquid Glass";
        case WAGRFeatureBundleAura: return @"Aura / WA Plus";
    }
    return @"Features";
}

static const char *WAGRFeatureSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRFeatureMethodIsBool(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    char t = WAGRFeatureSkipQualifiers(raw)[0];
    return t == 'B' || t == 'c';
}

static Method WAGRFeatureMethodForItem(NSDictionary *item) {
    NSString *className = item[kWAGRFeatureClass];
    NSString *selectorName = item[kWAGRFeatureSelector];
    BOOL meta = [item[kWAGRFeatureMeta] boolValue];
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    if (!cls || !selectorName.length) return NULL;
    SEL selector = NSSelectorFromString(selectorName);
    return meta ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
}

static BOOL WAGRFeatureItemIsHookableBool(NSDictionary *item) {
    return WAGRFeatureMethodIsBool(WAGRFeatureMethodForItem(item));
}

static BOOL WAGRFeatureItemIsWAABBool(NSDictionary *item) {
    return [item[kWAGRFeatureClass] isEqualToString:@"WAABProperties"] &&
           ![item[kWAGRFeatureMeta] boolValue] && WAGRFeatureItemIsHookableBool(item);
}

static id WAGRFeatureReceiverForClass(Class cls, SEL selector) {
    if (!cls || !selector) return nil;
    for (id object in WAGRABPropsResolveRuntimeObjects(nil)) {
        if ([object isKindOfClass:cls] && [object respondsToSelector:selector]) return object;
    }
    return nil;
}

static BOOL WAGRFeatureNativeBool(NSDictionary *item, BOOL *outValue) {
    NSString *className = item[kWAGRFeatureClass];
    NSString *selectorName = item[kWAGRFeatureSelector];
    BOOL meta = [item[kWAGRFeatureMeta] boolValue];
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = WAGRFeatureMethodForItem(item);
    if (!cls || !selector || !WAGRFeatureMethodIsBool(method)) return NO;
    @try {
        BOOL value = NO;
        if (meta) {
            value = ((BOOL (*)(id, SEL))objc_msgSend)((id)cls, selector);
        } else {
            id receiver = WAGRFeatureReceiverForClass(cls, selector);
            if (!receiver) {
                // If this exact target has already been hooked, RuntimeValueStore
                // may have captured the real receiver weakly during natural app use.
                id raw = nil;
                NSString *original = WAGRRuntimeValueReadOriginal(className, selectorName, NO, nil, &raw);
                if ([raw respondsToSelector:@selector(boolValue)] &&
                    ![original containsString:@"indisponível"]) {
                    if (outValue) *outValue = [raw boolValue];
                    return YES;
                }
                return NO;
            }
            value = ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
        if (outValue) *outValue = value;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL WAGRFeatureEffectiveBool(NSDictionary *item, BOOL *outValue, BOOL *outOverride) {
    NSString *selector = item[kWAGRFeatureSelector];
    if (WAGRGateIsSet(selector)) {
        if (outValue) *outValue = WAGRGateGet(selector);
        if (outOverride) *outOverride = YES;
        return YES;
    }
    if (outOverride) *outOverride = NO;
    return WAGRFeatureNativeBool(item, outValue);
}

static BOOL WAGRFeatureMasterEffective(WAGRFeatureBundleKind kind) {
    NSUInteger hookable = 0;
    for (NSDictionary *item in WAGRFeatureItemsForKind(kind)) {
        if (!WAGRFeatureItemIsHookableBool(item)) continue;
        hookable++;
        BOOL value = NO;
        // Do not silently ignore an exact current-build gate merely because its
        // live receiver has not been observed yet. Unknown required components
        // make the derived master OFF rather than producing a false-positive ON.
        if (!WAGRFeatureEffectiveBool(item, &value, NULL)) return NO;
        if (value != [item[kWAGRFeatureDesired] boolValue]) return NO;
    }
    return hookable > 0;
}

static void WAGRFeatureApplyHooks(WAGRFeatureBundleKind kind) {
    (void)WAGRWAABInstallHooksForAllRuntimeImages();
    (void)WAGRReinstallPersistedHooks();
    switch (kind) {
        case WAGRFeatureBundleInternal:
            WAGRDogfoodEnsureHooksInstalled();
            WAGRNativeDevMenuEnsureHooksInstalled();
            break;
        case WAGRFeatureBundleLiquidGlass:
            WAGRLGPrefsDidChange();
            break;
        case WAGRFeatureBundleAura:
            WAGRAuraEnsureHooksInstalled();
            WAGRAuraEnsureNavigationHooksInstalled();
            break;
    }
}

static void WAGRFeatureSetMaster(WAGRFeatureBundleKind kind, BOOL enabled) {
    for (NSDictionary *item in WAGRFeatureItemsForKind(kind)) {
        // Never create phantom GateStore entries for selectors that are absent or
        // ABI-incompatible in this WhatsApp build. A curated master only mutates
        // gates that are proven hookable in the loaded runtime.
        if (!WAGRFeatureItemIsHookableBool(item)) continue;
        NSString *selector = item[kWAGRFeatureSelector];
        if (enabled) WAGRGateSet(selector, [item[kWAGRFeatureDesired] boolValue]);
        else WAGRGateClear(selector);
    }
    WAGRFeatureApplyHooks(kind);
}

static NSString *WAGRFeatureABID(NSDictionary *item) {
    if (![item[kWAGRFeatureClass] isEqualToString:@"WAABProperties"]) return nil;
    return WAGRABPropsStableIDForTarget(@"WAABProperties",
                                        item[kWAGRFeatureSelector], NO);
}

@interface WAGRFeatureBundleDetailVC : UITableViewController
@property(nonatomic, assign) WAGRFeatureBundleKind kind;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@end

@implementation WAGRFeatureBundleDetailVC

- (instancetype)initWithKind:(WAGRFeatureBundleKind)kind {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _kind = kind;
    _items = WAGRFeatureItemsForKind(kind);
    self.title = WAGRFeatureTitleForKind(kind);
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = 58.0;
    self.tableView.estimatedRowHeight = 58.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyNow)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)applyNow {
    WAGRFeatureApplyHooks(self.kind);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 2; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.items.count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Conjunto" : @"Gates canônicos";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return @"O master é derivado dos próprios gates hookáveis deste build. Não existe um segundo storage. Azul = override compartilhado com ABProperties Browser; laranja = override salvo aguardando hook/receiver; verde = valor original. Desligar o master limpa os overrides e volta ao original.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = @"WAGRFeatureCanonicalSwitch";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.textLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.55;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.58;
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();

    UISwitch *toggle = [UISwitch new];
    toggle.tag = indexPath.section == 0 ? -1 : indexPath.row;
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;

    if (indexPath.section == 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"★ %@", WAGRFeatureTitleForKind(self.kind)];
        cell.detailTextLabel.text = @"Derivado; exige todos os componentes hookáveis conhecidos no estado desejado";
        toggle.on = WAGRFeatureMasterEffective(self.kind);
        toggle.onTintColor = UIColor.systemBlueColor;
        return cell;
    }

    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    NSString *selector = item[kWAGRFeatureSelector] ?: @"?";
    BOOL value = NO, overridden = NO;
    BOOL available = WAGRFeatureEffectiveBool(item, &value, &overridden);
    BOOL hookable = WAGRFeatureItemIsHookableBool(item);
    BOOL runtimeInstalled = WAGRFeatureItemIsWAABBool(item) && overridden &&
        WAGRRuntimeValueHookIsInstalled(@"WAABProperties", selector, NO);
    NSString *abID = WAGRFeatureABID(item);
    NSString *subtitle = item[kWAGRFeatureSubtitle] ?: @"";
    if (abID.length && [subtitle rangeOfString:@"AB "].location == NSNotFound) {
        subtitle = [subtitle stringByAppendingFormat:@" · AB %@", abID];
    }

    NSString *state = nil;
    if (!hookable) state = @"Ausente neste build";
    else if (overridden && WAGRFeatureItemIsWAABBool(item) && !runtimeInstalled) state = @"Override pendente";
    else if (overridden) state = @"Override";
    else if (available) state = @"Original";
    else state = @"Original aguardando receiver";

    cell.textLabel.text = selector;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", state, subtitle];
    toggle.on = available ? value : (overridden ? WAGRGateGet(selector) : NO);
    toggle.enabled = hookable || overridden;
    toggle.onTintColor = overridden
        ? ((WAGRFeatureItemIsWAABBool(item) && !runtimeInstalled) ? UIColor.systemOrangeColor : UIColor.systemBlueColor)
        : UIColor.systemGreenColor;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(clearOverride:)];
    longPress.minimumPressDuration = 0.45;
    [cell addGestureRecognizer:longPress];
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    if (sender.tag < 0) {
        WAGRFeatureSetMaster(self.kind, sender.isOn);
    } else if ((NSUInteger)sender.tag < self.items.count) {
        NSDictionary *item = self.items[(NSUInteger)sender.tag];
        if (WAGRFeatureItemIsHookableBool(item)) {
            WAGRGateSet(item[kWAGRFeatureSelector], sender.isOn);
            WAGRFeatureApplyHooks(self.kind);
        }
    }
    [self.tableView reloadData];
}

- (void)clearOverride:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)gesture.view;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath || indexPath.section != 1 || (NSUInteger)indexPath.row >= self.items.count) return;
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    NSString *selector = item[kWAGRFeatureSelector];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:selector
        message:@"Limpar este override e voltar ao valor original do runtime?"
        preferredStyle:UIAlertControllerStyleActionSheet];
    alert.popoverPresentationController.sourceView = cell;
    alert.popoverPresentationController.sourceRect = cell.bounds;
    [alert addAction:[UIAlertAction actionWithTitle:@"Voltar ao original" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            WAGRGateClear(selector);
            WAGRFeatureApplyHooks(self.kind);
            [self.tableView reloadData];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation WAGRFeatureBundlesVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Features / Experimentos";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = 62.0;
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return 3; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = @"WAGRFeatureBundlesRoot";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGRFeatureBundleKind kind = (WAGRFeatureBundleKind)indexPath.row;
    cell.textLabel.text = WAGRFeatureTitleForKind(kind);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu gates curados · mesma fonte do ABProperties Browser",
        (unsigned long)WAGRFeatureItemsForKind(kind).count];
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.72;
    cell.detailTextLabel.font = WAGRMenuDetailFont();
    cell.detailTextLabel.numberOfLines = 1;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGRFeatureBundleDetailVC *detail = [[WAGRFeatureBundleDetailVC alloc]
        initWithKind:(WAGRFeatureBundleKind)indexPath.row];
    [self.navigationController pushViewController:detail animated:YES];
}

@end