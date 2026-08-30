#import "WAGRABPropsPresetsVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRABPropsNativeOverrideEngine.h"
#import "../Runtime/WAGRLog.h"

extern id WAGRCurrentUserContext(void);

static NSDictionary *WAGRNativePresetPair(NSString *selector, id value) {
    return @{ @"selector" : selector ?: @"", @"value" : value ?: NSNull.null };
}

static NSString *WAGRMetaVerifiedSubscriptionConfig(void) {
    // This is the exact JSON assembled through Swift string interpolation by
    // the 26.33 preset helper. Keep it as a string: smb_subscription_config is
    // an object/string ABProp, not an NSDictionary payload.
    return @"{\n"
            @"    \"com.whatsapp.w4b.1000000000000000\": {\n"
            @"      \"purchase_origin\": \"meta_business_suite\"\n"
            @"    },\n"
            @"    \"com.whatsapp.mv4b.6937685799644206\": {\n"
            @"      \"purchase_origin\": \"in_app_purchase\"\n"
            @"    }\n"
            @"}";
}

static NSArray<NSDictionary *> *WAGRBluePremiumPairs(void) {
    return @[
        WAGRNativePresetPair(@"smb_biz_tools_reorder", @YES),
        WAGRNativePresetPair(@"smb_billing_logging_enabled", @YES),
        WAGRNativePresetPair(@"smb_premium_additional_logging_enabled", @YES),
        WAGRNativePresetPair(@"smb_premium_awareness_banner_enabled", @YES),
        WAGRNativePresetPair(@"smb_billing_ios_receipt_on_quote_enabled", @YES),
        WAGRNativePresetPair(@"smb_premium_deeplink_handling_enabled", @YES),
        WAGRNativePresetPair(@"smb_melon_management_enabled", @YES),
        WAGRNativePresetPair(@"smb_custom_url_display_v2_enabled", @YES),
        WAGRNativePresetPair(@"smb_melon_display_enabled", @YES),
        WAGRNativePresetPair(@"smb_melon_logging_enabled", @YES),
        WAGRNativePresetPair(@"smb_custom_url_qpl_enabled", @YES),
        WAGRNativePresetPair(@"smb_biz_profile_custom_url_notifications", @YES),
        WAGRNativePresetPair(@"call_only_primary_device_limit_exceeded", @YES),
        WAGRNativePresetPair(@"smb_multi_device_agents_enabled", @YES),
        WAGRNativePresetPair(@"smb_multi_device_message_attribution_enabled", @YES),
        WAGRNativePresetPair(@"smb_multi_device_agents_logging_V2_enabled", @YES),
        WAGRNativePresetPair(@"smb_md_agent_chat_assignment_enabled", @YES),
        WAGRNativePresetPair(@"smb_md_agent_chat_assignment_nux_impressions", @3),
        WAGRNativePresetPair(@"smb_md_agent_chat_assignment_system_messages_enabled", @YES),
        WAGRNativePresetPair(@"smb_md_agent_chat_assignment_chats_reorder_on_chat_unassignment_enabled", @YES),
        WAGRNativePresetPair(@"smb_md_agent_chat_assignment_chats_reorder_on_chat_assignment_enabled", @YES),
        WAGRNativePresetPair(@"smb_md_agent_chat_assignment_system_messages_logging_v2_enabled", @YES),
        WAGRNativePresetPair(@"premium_blue_enabled", @YES),
        WAGRNativePresetPair(@"smbi_meta_verified_phase_1b_prototype", @NO),
        WAGRNativePresetPair(@"smb_premium_awareness_banner_enabled", @NO),
        WAGRNativePresetPair(@"blue_strings_enabled", @YES),
        WAGRNativePresetPair(@"blue_enabled", @YES),
        WAGRNativePresetPair(@"blue_education_enabled", @YES),
        WAGRNativePresetPair(@"blue_profile_locked_ui_enabled", @YES),
        WAGRNativePresetPair(@"smb_meta_verified_phase_1b_eligibility", @YES),
        WAGRNativePresetPair(@"smb_meta_verified_phase_1b_eligibility_sync_frequency", @86400),
        WAGRNativePresetPair(@"smb_subscription_config", WAGRMetaVerifiedSubscriptionConfig()),
    ];
}

static NSArray<NSDictionary *> *WAGRStoreKit2Pairs(void) {
    return @[
        WAGRNativePresetPair(@"smb_meta_verified_storekit_2_enabled", @YES),
        WAGRNativePresetPair(@"wa_ios_storekit2_cache_fetched_products", @YES),
        WAGRNativePresetPair(@"wa_ios_storekit2_skip_apple_product_param", @YES),
        WAGRNativePresetPair(@"wa_ios_storekit2_skip_product_fetch_during_verify_purchase_enabled", @YES),
        WAGRNativePresetPair(@"wa_ios_storekit2_send_purchase_result_info_to_nme", @YES),
        WAGRNativePresetPair(@"wa_ios_storekit2_skip_sku_fetch_before_quote_create_enabled", @YES),
        WAGRNativePresetPair(@"wa_ios_iap_storekit2_pending_purchase_as_error_enabled", @YES),
    ];
}

static NSArray<NSDictionary *> *WAGRNativeDebugPresets(void) {
    static NSArray<NSDictionary *> *presets = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *metaVerified = [WAGRBluePremiumPairs() mutableCopy];
        [metaVerified addObjectsFromArray:@[
            WAGRNativePresetPair(@"smbi_meta_verified_phase_1b_prototype", @YES),
            WAGRNativePresetPair(@"meta_verified_phase_1b_use_unified_entrypoint", @YES),
            WAGRNativePresetPair(@"meta_verified_notifications_enabled", @YES),
        ]];

        NSMutableArray *partnerBilling = [WAGRStoreKit2Pairs() mutableCopy];
        [partnerBilling addObjectsFromArray:@[
            WAGRNativePresetPair(@"wa_ios_iap_pb_payhub_enabled", @YES),
            WAGRNativePresetPair(@"wa_ios_iap_pb_payhub_params_enabled", @YES),
        ]];

        presets = @[
            @{ @"identifier" : @"smbmktmsgs", @"title" : @"SMB Marketing Messages", @"native_title" : @"Set ABProps to enable SMB Marketing Messages.", @"pairs" : @[
                WAGRNativePresetPair(@"smb_rambutan_enabled", @YES),
                WAGRNativePresetPair(@"smb_rambutan_product_ids", @"com.whatsapp.w4b.3334815046829569,com.whatsapp.w4b.753666849513385,com.whatsapp.w4b.consumable.test.1,com.whatsapp.w4b.consumable.test.2"),
            ] },
            @{ @"identifier" : @"smbmetaverifiedphase1a", @"title" : @"SMB Blue Premium", @"native_title" : @"Set ABProps to enable all SMB Blue Premium features.", @"pairs" : WAGRBluePremiumPairs() },
            @{ @"identifier" : @"smbmetaverifiedphase1b", @"title" : @"SMB Meta Verified · prod", @"native_title" : @"Set ABProps to enable all SMB Meta Verified features for prod release.", @"pairs" : metaVerified },
            // The current RC compiles this preset with Array.empty. Showing it
            // is useful evidence; applying invented AI flags would not be.
            @{ @"identifier" : @"smbbusinessassistant", @"title" : @"Meta AI for Business · Business Assistant", @"native_title" : @"Set ABProps to enable Meta AI for Business on DEBUG SMB app as Business Assistant", @"pairs" : @[], @"native_noop" : @YES },
            @{ @"identifier" : @"mv_storekit2", @"title" : @"Meta Verified StoreKit2", @"native_title" : @"Set ABProps to enable Meta Verified StoreKit2 abprops", @"pairs" : WAGRStoreKit2Pairs() },
            @{ @"identifier" : @"mv_partner_billing", @"title" : @"Meta Verified Partner Billing", @"native_title" : @"Set ABProps to enable Meta Verified Partner Billing abprops", @"pairs" : partnerBilling },
            @{ @"identifier" : @"iap_codegen_and_parse_errors", @"title" : @"IAP GraphQL codegen / errors", @"native_title" : @"Set ABProps to enable IAP graphql codegen and error parsing", @"pairs" : @[
                WAGRNativePresetPair(@"wa_ios_generated_dcp_queries_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_dcp_query_product_info_codegen_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_dcp_create_iap_purchase_quote_codegen_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_dcp_verify_purchase_codegen_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_graphql_fetch_price_dcp_parse_errors_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_graphql_verify_purchase_dcp_parse_errors_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_graphql_verify_purchase_dcp_parse_purchase_errors_value_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_graphql_quote_create_dcp_parse_errors_enabled", @YES),
            ] },
            @{ @"identifier" : @"smb_premium_broadcast", @"title" : @"Enable Business Broadcast", @"native_title" : @"Set ABProps to ENABLE SMB Business Broadcast abProps", @"pairs" : @[
                WAGRNativePresetPair(@"smbi_premium_broadcast_enabled", @YES),
                WAGRNativePresetPair(@"smbi_premium_broadcast_nse_send_enabled", @YES),
                WAGRNativePresetPair(@"smbi_premium_broadcast_quota_rehydrate_interval", @5),
            ] },
            @{ @"identifier" : @"disable_smb_premium_broadcast", @"title" : @"Disable Business Broadcast", @"native_title" : @"Set ABProps to DISABLE SMB Business Broadcast abProps", @"pairs" : @[
                WAGRNativePresetPair(@"smbi_premium_broadcast_enabled", @NO),
                WAGRNativePresetPair(@"smbi_premium_broadcast_nse_send_enabled", @NO),
                WAGRNativePresetPair(@"smbi_premium_broadcast_quota_rehydrate_interval", @1440),
            ] },
            @{ @"identifier" : @"smb_send_limit", @"title" : @"Enable Business Broadcast Send Limit", @"native_title" : @"Set ABProps to ENABLE SMB Business Broadcast Send Limit abProps", @"pairs" : @[
                WAGRNativePresetPair(@"smbi_premium_broadcast_increased_send_limit_enabled", @YES),
                WAGRNativePresetPair(@"smbi_premium_broadcast_increased_limit_picker_ui_enabled", @YES),
                WAGRNativePresetPair(@"smbi_premium_broadcast_max_recipient_limit", @500),
            ] },
            @{ @"identifier" : @"disable_smb_send_limit", @"title" : @"Disable Business Broadcast Send Limit", @"native_title" : @"Set ABProps to DISABLE SMB Business Broadcast Send Limit abProps", @"pairs" : @[
                WAGRNativePresetPair(@"smbi_premium_broadcast_increased_send_limit_enabled", @NO),
                WAGRNativePresetPair(@"smbi_premium_broadcast_increased_limit_picker_ui_enabled", @NO),
                WAGRNativePresetPair(@"smbi_premium_broadcast_max_recipient_limit", @256),
            ] },
            @{ @"identifier" : @"consumer_bl_capping", @"title" : @"Enable Consumer Broadcast List Capping", @"native_title" : @"Set ABProps to ENABLE Consumer Broadcast List Capping abProps", @"pairs" : @[
                WAGRNativePresetPair(@"wa_ios_premium_broadcast_consumer_capping_enabled", @YES),
                WAGRNativePresetPair(@"wa_ios_premium_broadcast_consumer_quota_rehydrate_interval", @5),
            ] },
            @{ @"identifier" : @"disable_consumer_bl_capping", @"title" : @"Disable Consumer Broadcast List Capping", @"native_title" : @"Set ABProps to DISABLE Consumer Broadcast List Capping abProps", @"pairs" : @[
                WAGRNativePresetPair(@"wa_ios_premium_broadcast_consumer_capping_enabled", @NO),
                WAGRNativePresetPair(@"wa_ios_premium_broadcast_consumer_quota_rehydrate_interval", @1440),
            ] },
        ];
    });
    return presets;
}

static NSArray<NSDictionary *> *WAGRUniqueEffectivePairs(NSArray<NSDictionary *> *pairs) {
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *reversed = [NSMutableArray array];
    for (NSDictionary *pair in pairs.reverseObjectEnumerator) {
        NSString *selector = pair[@"selector"];
        if (!selector.length || [seen containsObject:selector]) continue;
        [seen addObject:selector];
        [reversed addObject:pair];
    }
    return [[reversed reverseObjectEnumerator] allObjects];
}

@interface WAGRABPropsPresetsVC ()
@property(nonatomic, strong, nullable) id userContext;
@property(nonatomic, copy) NSArray<NSDictionary *> *presets;
@property(nonatomic, assign) BOOL applying;
@end

@implementation WAGRABPropsPresetsVC

- (instancetype)initWithUserContext:(id)userContext {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _userContext = userContext;
    _presets = WAGRNativeDebugPresets();
    self.title = @"Native Debug Presets";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.presets.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return @"Presets compilados no WhatsApp 26.33";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Os pares selector/valor vêm do array Swift nativo. Antes de escrever, cada selector é reencontrado no runtime, seu stable ID ARM64 é decodificado e o writer StartupConfigs exige readback persistido e valor efetivo.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRNativePresetCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRNativePresetCell"];
    NSDictionary *preset = self.presets[(NSUInteger)indexPath.row];
    NSArray *pairs = WAGRUniqueEffectivePairs(preset[@"pairs"]);
    BOOL noop = [preset[@"native_noop"] boolValue];
    WAGRMenuApplyCellStyle(cell, indexPath.row, preset[@"identifier"]);
    cell.textLabel.text = preset[@"title"];
    cell.detailTextLabel.text = noop
        ? @"No-op comprovado nesta RC · payload nativo = Array.empty"
        : [NSString stringWithFormat:@"%lu ABProps · %@", (unsigned long)pairs.count, preset[@"identifier"]];
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = WAGRMenuSymbol(noop ? @"nosign" : @"switch.2", nil);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = self.applying ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.applying) return;
    NSDictionary *preset = self.presets[(NSUInteger)indexPath.row];
    NSArray<NSDictionary *> *pairs = WAGRUniqueEffectivePairs(preset[@"pairs"]);
    if ([preset[@"native_noop"] boolValue]) {
        [self showAlert:@"Preset nativo sem payload"
                message:@"O inicializador 26.33 associa este título a Array.empty. O WATweaks mantém a entrada visível como evidência e não fabrica ABProps para fazê-la parecer funcional."];
        return;
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:pairs.count];
    for (NSDictionary *pair in pairs) {
        [lines addObject:[NSString stringWithFormat:@"%@ = %@", pair[@"selector"], pair[@"value"]]];
    }
    NSString *preview = [lines componentsJoinedByString:@"\n"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:preset[@"title"]
        message:[NSString stringWithFormat:@"%@\n\n%@", preset[@"native_title"], preview]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Aplicar pelo writer nativo" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf applyPreset:preset];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyPreset:(NSDictionary *)preset {
    id context = self.userContext ?: WAGRCurrentUserContext();
    if (!context) {
        [self showAlert:@"AB Props" message:@"O userContext account-scoped ainda não foi capturado. Abra novamente o Developer Menu e tente outra vez."];
        return;
    }
    self.applying = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]];
    UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)self.navigationItem.rightBarButtonItem.customView;
    [spinner startAnimating];
    [self.tableView reloadData];

    NSArray<NSDictionary *> *pairs = WAGRUniqueEffectivePairs(preset[@"pairs"]);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = WAGRABPropsResolveRuntimeObjects(context);
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        NSMutableDictionary<NSString *, WAGRABPropEntry *> *bySelector = [NSMutableDictionary dictionary];
        for (WAGRABPropEntry *entry in entries) {
            if (!entry.selectorName.length || bySelector[entry.selectorName]) continue;
            NSString *stable = WAGRABPropsStableIDForTarget(entry.className, entry.selectorName, entry.classMethod);
            if (stable.length) bySelector[entry.selectorName] = entry;
        }

        NSMutableArray<NSDictionary *> *resolved = [NSMutableArray array];
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        for (NSDictionary *pair in pairs) {
            NSString *selector = pair[@"selector"];
            WAGRABPropEntry *entry = bySelector[selector];
            NSString *stable = entry ? WAGRABPropsStableIDForTarget(entry.className, entry.selectorName, entry.classMethod) : nil;
            if (!stable.length) {
                [missing addObject:selector ?: @"?"];
                continue;
            }
            [resolved addObject:@{ @"stable_id" : stable, @"selector" : selector, @"value" : pair[@"value"] ?: NSNull.null }];
        }

        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        NSUInteger applied = 0;
        NSDictionary *before = WAGRABPropsNativeTrackedOverrides();
        NSMutableArray<NSString *> *changed = [NSMutableArray array];
        if (!missing.count) {
            for (NSDictionary *item in resolved) {
                NSError *error = nil;
                NSString *diagnostic = nil;
                NSString *stable = item[@"stable_id"];
                if (WAGRABPropsNativeSetOverride(stable, item[@"value"], context, &error, &diagnostic)) {
                    applied++;
                    [changed addObject:stable];
                } else {
                    [failures addObject:[NSString stringWithFormat:@"%@ (AB %@): %@", item[@"selector"], stable, error.localizedDescription ?: diagnostic ?: @"falhou"]];
                    break;
                }
            }
        }

        BOOL rolledBack = NO;
        if (missing.count || failures.count) {
            rolledBack = changed.count > 0;
            for (NSString *stable in changed.reverseObjectEnumerator) {
                id previous = before[stable];
                if (previous) WAGRABPropsNativeSetOverride(stable, previous, context, NULL, NULL);
                else WAGRABPropsNativeClearOverride(stable, context, NULL, NULL);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.applying = NO;
            self.navigationItem.rightBarButtonItem = nil;
            [self.tableView reloadData];
            if (missing.count) {
                [self showAlert:@"Preset não aplicado"
                        message:[NSString stringWithFormat:@"Preflight atômico bloqueou a escrita: %lu selectors não existem com stable ID verificável nesta build.\n\n%@", (unsigned long)missing.count, [missing componentsJoinedByString:@"\n"]]];
            } else if (failures.count) {
                [self showAlert:@"Preset revertido"
                        message:[NSString stringWithFormat:@"Aplicados antes da falha: %lu\nRollback: %@\n\n%@", (unsigned long)applied, rolledBack ? @"executado" : @"não necessário", [failures componentsJoinedByString:@"\n"]]];
            } else {
                WAGRLogAppendF(@"[NativePresets] %@ applied=%lu", preset[@"identifier"], (unsigned long)applied);
                [self showAlert:@"Preset aplicado"
                        message:[NSString stringWithFormat:@"%@\n\n%lu overrides passaram por persistência + readback efetivo.", preset[@"title"], (unsigned long)applied]];
            }
        });
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
