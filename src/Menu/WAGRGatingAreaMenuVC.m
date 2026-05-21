// WAGRGatingAreaMenuVC.m
// ─────────────────────────────────────────────────────────────────────────────
// Implementation notes
// ────────────────────
// Each row hosts a UISwitch as accessoryView. The switch is bound to the
// override key returned by WAGROverrideKeyFor(class, sel, isClassMethod).
// Toggling the switch writes the appropriate boolean to NSUserDefaults
// directly — the existing WAGRObjCHookRouter reinstall pass picks up the
// new key at the next startup or when the user taps "Reinstall hooks"
// from the Advanced menu.
//
// The 3-state semantic that the router uses (YES / NO / absent) maps to
// the switch like this:
//   • switch ON  → override key present and YES (force gate to YES)
//   • switch OFF → override key removed entirely (no override; gate uses
//                  WhatsApp's original logic)
// For inverted entries, "switch ON" still writes YES — the inversion is
// handled at the trampoline layer by the router consulting entry.inverted
// when it computes the return value. Keeping the persistence uniform
// regardless of inverted lets the router treat all overrides identically.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRGatingAreaMenuVC.h"
#import "../WAGramPrefix.h"
#import <objc/runtime.h>

// The router needs to be told that an override changed so it can install
// the hook live if the user toggled while the app is running. We rely on
// a small re-install entry point exposed by WAGRObjCHookRouter.
extern NSUInteger WAGRReinstallPersistedHooks(void);
extern void WAGRWAABEnsureHooksInstalled(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern void WAGRSettingsRowsNativeEnsureHooksInstalled(void);

// Associated-object key for stashing the entry pointer on each switch so
// the switch's target/action can recover which catalog entry it corresponds
// to without keeping a parallel index<->entry map.
static const void *kWAGREntryAssocKey = &kWAGREntryAssocKey;


static NSString *WAGRWAABOverrideKeyForFlag(NSString *flag) {
    return WAGROverrideKeyFor(@"WAABProperties", flag, NO);
}

static void WAGRApplyWAABBundle(NSArray<NSString *> *flags, BOOL enabled, BOOL physicalValue) {
    for (NSString *flag in flags) {
        NSString *key = WAGRWAABOverrideKeyForFlag(flag);
        if (enabled) WAGRSetOverride(key, physicalValue);
        else WAGRClearOverride(key);
    }
}


static void WAGRApplyObjCBoolOverride(NSString *className, NSString *selectorName, BOOL isClassMethod, BOOL enabled, BOOL physicalValue) {
    NSString *key = WAGROverrideKeyFor(className, selectorName, isClassMethod);
    if (enabled) WAGRSetOverride(key, physicalValue);
    else WAGRClearOverride(key);
}

static NSArray<NSString *> *WAGRWDSSelectorsForLiquidSelector(NSString *selectorName) {
    NSString *s = selectorName.lowercaseString ?: @"";
    NSMutableArray<NSString *> *sels = [NSMutableArray array];

    if ([s containsString:@"liquid_glass_enabled"] || [s isEqualToString:@"ios_liquid_glass_launched"] || [s isEqualToString:@"wa_lg_ios_liquid_glass_enabled"]) {
        [sels addObjectsFromArray:@[@"hasLiquidGlassLaunched", @"isM0Enabled"]];
    }
    if ([s containsString:@"m1"] && ![s containsString:@"m_1_5"] && ![s containsString:@"m1_5"]) [sels addObject:@"isM1Enabled"];
    if ([s containsString:@"m_1_5"] || [s containsString:@"m1_5"]) [sels addObject:@"isM1_5Enabled"];
    if ([s containsString:@"context_menu"]) [sels addObject:@"isM1_5ContextMenuEnabled"];
    if ([s containsString:@"new_chatbar"]) [sels addObject:@"isNewChatbarUXEnabled"];
    if ([s containsString:@"chatbar_lower_bottom_padding"]) [sels addObject:@"isChatbarLowerBottomPaddingEnabled"];
    if ([s containsString:@"chat_top_bar"]) [sels addObject:@"isChatTopBarM2Enabled"];
    if ([s containsString:@"text_layout"]) [sels addObject:@"isTextLayoutM2Enabled"];
    if ([s containsString:@"action_tile"]) [sels addObject:@"isActionTileM2Enabled"];
    if ([s containsString:@"unify_ui"]) [sels addObject:@"isUnifyUIRefreshEnabled"];
    if ([s containsString:@"unify_navigation"]) [sels addObject:@"isUnifyNavigationBarEnabled"];
    if ([s containsString:@"native_swipe"]) [sels addObject:@"shouldUseNativeSwipeActions"];
    if ([s containsString:@"native_sidebar"] || [s containsString:@"unify_native_sidebar"]) [sels addObject:@"isNativeSidebarEnabled"];
    if ([s containsString:@"hides_bottombar"]) [sels addObject:@"isHidingBottomBarWorkaroundEnabled"];
    if ([s containsString:@"topbar_appearance"]) [sels addObject:@"isTopBarAppearanceWorkaroundEnabled"];
    if ([s containsString:@"fixes_for_older"]) [sels addObject:@"isFixesForOlderOSEnabled"];
    if ([s containsString:@"fix_tabbar_badge"]) [sels addObject:@"isFixTabbarBadgeOffthreadEnabled"];
    if ([s containsString:@"transition_safety"]) [sels addObject:@"isContextMenuTransitionSafetyFixEnabled"];
    if ([s containsString:@"on_disappear"]) [sels addObject:@"isFixContextMenuOnDisappearEnabled"];
    if ([s containsString:@"updates_table_dynamic_color"]) [sels addObject:@"isFixUpdatesTableDynamicColorEnabled"];

    return sels;
}

static void WAGRApplyRelatedObjCChain(WAGRGatingEntry *entry, BOOL enabled) {
    if (entry.area != WAGRGatingAreaLiquidGlass) return;
    NSArray<NSString *> *selectors = WAGRWDSSelectorsForLiquidSelector(entry.selectorName);
    for (NSString *sel in selectors) {
        WAGRApplyObjCBoolOverride(@"WDSLiquidGlass", sel, YES, enabled, YES);
    }
    if (selectors.count) {
        NSLog(@"[WATweaks][Catalog] %@ WDSLiquidGlass alias chain for %@ (%lu selectors)",
              enabled ? @"enabled" : @"cleared", entry.selectorName, (unsigned long)selectors.count);
    }
}

static NSArray<NSString *> *WAGRRelatedWAABFlagsForSelector(NSString *selectorName) {
    NSString *s = selectorName.lowercaseString ?: @"";


    if ([s containsString:@"liquid"] || [s containsString:@"glass"] || [s containsString:@"chatbar"] ||
        [s containsString:@"topbar"] || [s containsString:@"bottombar"] || [s containsString:@"m0"] ||
        [s containsString:@"m1"] || [s containsString:@"actiontile"] || [s containsString:@"unify"] ||
        [s containsString:@"nativebar"] || [s containsString:@"sidebar"]) {
        return @[
            @"wa_lg_ios_liquid_glass_enabled", @"wa_lg_ios_liquid_glass_launched",
            @"wa_lg_ios_liquid_glass_m1", @"wa_lg_ios_liquid_glass_m_1_5",
            @"wa_lg_ios_liquid_glass_m_1_5_context_menu", @"wa_lg_ios_liquid_glass_chat_top_bar_m2_enabled",
            @"wa_lg_ios_liquid_glass_enable_new_chatbar_ux", @"wa_lg_ios_liquid_glass_larger_composer",
            @"wa_lg_ios_liquid_glass_reduce_transparency", @"wa_lg_ios_liquid_glass_workaround_attachment_tray",
            @"wa_lg_ios_liquid_glass_workaround_hides_bottombar", @"wa_lg_ios_liquid_glass_workaround_topbar_appearance",
            @"ios_liquid_glass_enabled", @"ios_liquid_glass_launched", @"ios_liquid_glass_m1",
            @"ios_liquid_glass_m_1_5", @"ios_liquid_glass_m_1_5_context_menu",
            @"ios_liquid_glass_chat_top_bar_m2_enabled", @"ios_liquid_glass_enable_new_chatbar_ux",
            @"ios_liquid_glass_larger_composer", @"ios_liquid_glass_media_m0",
            @"ios_liquid_glass_media_editor_enabled", @"ios_liquid_glass_calling_improvement_enabled",
            @"ios_liquid_glass_workaround_attachment_tray"
        ];
    }
    if ([s containsString:@"aura"] || [s containsString:@"subscription"] || [s containsString:@"ringtones"] || [s containsString:@"ringtone"]) {
        return @[
            @"aura_enabled", @"aura_settings_row_enabled", @"aura_subscription_simulation_enabled",
            @"wa_subscriptions_entry_point_settings_enabled", @"wa_subscriptions_settings_green_dot_enabled",
            @"premium_blue_enabled",
            @"aura_ringtones_enabled", @"aura_ringtones_benefit_active", @"aura_ringtones_per_chat_enabled",
            @"wa_plus_custom_ringtones", @"meta_subs_benefit_wa_ringtones_upsell",
            @"aura_app_icon_enabled", @"aura_app_icon_benefit_active", @"aura_app_icon_multi_account_support",
            @"aura_app_themes_enabled", @"aura_app_themes_benefit_active",
            @"aura_stickers_enabled", @"aura_stickers_benefit_active",
            @"aura_pinned_chats_enabled", @"aura_pinned_chats_benefit_active",
            @"aura_enhanced_lists_enabled", @"aura_enhanced_lists_benefit_active",
            @"isEligibleForSubscriptions", @"isRingtonesBenefitActive", @"isAISubscriptionEnabled", @"isSubscribedToAiBenefit"
        ];
    }

    if ([s containsString:@"payment"] || [s containsString:@"payments"] || [s containsString:@"upi"] || [s containsString:@"pix"] || [s containsString:@"br_consumer"]) {
        return @[
            @"br_consumer_payments_home_enabled", @"br_consumer_paymentshome_enabled",
            @"payments_home_revamp_m1_enabled", @"payments_home_revamp_landing_screen_enabled", @"payments_home_ui_updates_enabled",
            @"payment_settings_add_bank_account_row", @"payment_settings_add_upi_number_row", @"payment_settings_add_bank_banner",
            @"payment_settings_invite_others_row", @"payment_settings_remove_payment_info_row",
            @"br_payments_pix_native_enabled", @"br_payments_pix_groups_enabled", @"br_p2p_add_pix_key_from_payment_settings",
            @"br_payment_smb_connect_to_bank_enabled", @"br_payments_passkey_enable", @"enable_payment_passkey",
            @"is_upi_global_enabled", @"payments_upi_global_enabled", @"payments_upi_bank_list_graphql_enabled", @"payments_upi_get_accounts_graphql"
        ];
    }

    if ([s containsString:@"companion"] || [s containsString:@"primary"] || [s containsString:@"linked"] || [s containsString:@"device"] || [s containsString:@"webclient"]) {
        return @[
            @"ios_linked_devices_empty_states_ui_refresh_enabled", @"linked_devices_send_link_cta_ios", @"linked_devices_apple_watch",
            @"md_linked_devices_badging_journey", @"companion_support_enabled", @"companion_contact_change_enabled",
            @"companion_lid_contact_change_enabled", @"native_contacts_primary_allows_mutations_from_companions",
            @"primary_lists_support", @"primary_favorites_sync_support", @"lists_sync_enabled", @"call_favorites_enabled_companions",
            @"username_enabled_on_companion", @"enable_status_on_companion", @"device_capabilities_sync_enabled"
        ];
    }

    if ([s containsString:@"foa"] || [s containsString:@"bookmark"] || [s containsString:@"threads"] || [s containsString:@"horizon"] || [s containsString:@"vibes"]) {
        return @[
            @"foa_bookmarks_enabled", @"foa_bookmarks_logging_enabled", @"foa_bookmark_sk_overlay_enabled",
            @"foa_threads_bookmarks_enabled", @"foa_bridges_bookmark_meta_horizon", @"foa_bridges_bookmarks_design_update_enabled",
            @"foa_bridges_account_switcher_ios_enabled", @"ai_rich_response_vibes_promotion_enabled", @"ai_rich_response_c50_promotion_enabled",
            @"wa_bookmarks_hs_fb_cta", @"wa_bookmarks_hs_ig_cta", @"wa_bookmarks_hs_meta_ai_cta",
            @"wa_bookmarks_hs_meta_horizon_cta", @"wa_bookmarks_hs_threads_cta", @"wa_bookmarks_hs_vibes_cta"
        ];
    }

    if ([s containsString:@"waffle"]) {
        return @[
            @"waffle_mobile_companions_enabled", @"waffle_companions_enabled",
            @"waffle_enabled_for_linked_users", @"waffle_enabled_for_unlinked_users",
            @"waffle_foa_to_wa_linking_enabled", @"waffle_v3_fx_settings_redesign_v1",
            @"waffle_v3_ios_use_client_values_to_reduce_settings_bloks_payload"
        ];
    }

    if ([s containsString:@"group"] || [s containsString:@"history"] || [s containsString:@"subgroup"]) {
        return @[
            @"group_history_send_enabled", @"group_history_setting_ui_enabled",
            @"group_status_enabled", @"group_status_setting_ui_enabled", @"enable_status_on_companion",
            @"allow_lid_contacts_add_to_group", @"add_non_contacts_to_groups_enabled",
            @"add_non_contact_to_group", @"allowNonAdminSubGroupCreation",
            @"add_member_group_ranking_allow_non_contact", @"add_member_group_recommendation_recent_cut_off_hours"
        ];
    }


    if ([s containsString:@"evolve"] || [s containsString:@"about"] || [s containsString:@"contact_"] || [s containsString:@"profile_"] || [s containsString:@"bubble"]) {
        return @[
            @"evolve_about_m1_enabled", @"evolve_about_m1_receiver_enabled",
            @"evolve_about_m1_receiver_for_new_surfaces_enabled", @"evolve_about_m2_contact_card_thought_bubble_enabled",
            @"evolve_about_migration_fix_enabled", @"about_creation_sheet",
            @"about_emoji_badge_in_group_sender_name_enabled", @"privacy_settings_about_lid_migration_enable",
            @"add_status_tile_center_profile_photo_enabled", @"contact_phone_number_cell_refactor_enabled",
            @"contact_username_cell_refactor_enabled", @"contact_sync_toggle_cell_refactor_enabled",
            @"contacts_sync_toggle_refactor_v2", @"contact_ui_refresh_phone_number_enabled",
            @"ios_evolution_contacts_list_item_migration", @"ios_evolution_contacts_list_item_migration_part_2",
            @"ios_borderless_media_bubbles_enabled", @"ios_wds_label_in_chat_date_bubble_enabled",
            @"profile_header_blue_badge", @"classic_profile_screen_notable_badge", @"blue_profile_locked_ui_enabled",
            @"default_profile_pics_m1", @"client_profile_photo_sync_m1_enabled_no_expo"
        ];
    }

    return @[];
}

static void WAGRApplyRelatedSettingsRowChain(WAGRGatingEntry *entry, BOOL enabled, BOOL physicalValue) {
    NSArray<NSString *> *related = WAGRRelatedWAABFlagsForSelector(entry.selectorName);
    if (related.count == 0) return;
    WAGRApplyWAABBundle(related, enabled, physicalValue);
    NSLog(@"[WATweaks][Catalog] %@ related Settings-row chain for %@ (%lu flags)",
          enabled ? @"enabled" : @"cleared", entry.selectorName, (unsigned long)related.count);
}

@interface WAGRGatingAreaMenuVC ()
@property(nonatomic, assign) WAGRGatingArea area;
@property(nonatomic, copy)   NSArray<WAGRGatingEntry *> *entries;
@end

@implementation WAGRGatingAreaMenuVC

- (instancetype)initWithArea:(WAGRGatingArea)area {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _area    = area;
    _entries = [WAGRGatingCatalog entriesForArea:area];
    self.title = WAGRGatingAreaTitle(area);
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
    self.tableView.allowsSelection = NO;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    // Section 0: gates list (or empty-state).
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    // If the area has no curated entries yet, we still show one row that
    // tells the user this area is scaffolded but empty. This is friendlier
    // than a silently empty screen.
    return MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return WAGRGatingAreaSubtitle(self.area);
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (self.entries.count == 0) {
        return @"This area's catalog is empty. Open WAGRGatingCatalog.m to add entries — see WAGRGatingAreaAura / WAGRGatingAreaHiddenRows for the format.";
    }
    return [NSString stringWithFormat:@"%lu gates · toggles persist as wagr.override.* keys",
            (unsigned long)self.entries.count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];

    // Empty-state row.
    if (self.entries.count == 0) {
        c.textLabel.text = @"No curated gates for this area yet";
        c.textLabel.textColor = UIColor.tertiaryLabelColor;
        c.detailTextLabel.text = @"Extend WAGRGatingCatalog.m to populate.";
        c.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }

    WAGRGatingEntry *e = self.entries[ip.row];
    c.textLabel.text = e.title;
    c.textLabel.textColor = UIColor.labelColor;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = e.desc;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;

    // Build a switch that reflects the persisted override state.
    UISwitch *sw = [[UISwitch alloc] init];
    NSString *key = WAGROverrideKeyFor(e.className, e.selectorName, e.isClassMethod);
    sw.on = WAGRHasOverride(key);
    objc_setAssociatedObject(sw, kWAGREntryAssocKey, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;

    return c;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tv estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip {
    return 66;
}

#pragma mark - Toggle

- (void)switchChanged:(UISwitch *)sw {
    WAGRGatingEntry *e = objc_getAssociatedObject(sw, kWAGREntryAssocKey);
    if (!e) return;

    NSString *key = WAGROverrideKeyFor(e.className, e.selectorName, e.isClassMethod);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    BOOL physicalValue = !e.inverted;
    if (sw.on) {
        // Use the shared override helper instead of writing NSUserDefaults
        // directly. For WAABProperties entries this mirrors the value into
        // wagr.waab.<flag>, which is the storage read by WAABPropsObserver and
        // by boolForKey:defaultValue:. Without this mirror, Settings-row
        // toggles are visually ON but WhatsApp still reads the original gates.
        WAGRSetOverride(key, physicalValue);
        WAGRApplyRelatedSettingsRowChain(e, YES, YES);
        WAGRApplyRelatedObjCChain(e, YES);
        NSLog(@"[WATweaks][Catalog] override ON  for %@ %c%@ (physical=%@ key=%@)",
              e.className, e.isClassMethod ? '+' : '-', e.selectorName, physicalValue ? @"YES" : @"NO", key);
    } else {
        WAGRClearOverride(key);
        WAGRApplyRelatedSettingsRowChain(e, NO, physicalValue);
        WAGRApplyRelatedObjCChain(e, NO);
        NSLog(@"[WATweaks][Catalog] override OFF for %@ %c%@ (physical=%@ key=%@)",
              e.className, e.isClassMethod ? '+' : '-', e.selectorName, physicalValue ? @"YES" : @"NO", key);
    }
    [ud synchronize];

    // Live-install all relevant owners. WAAB covers flag-backed rows, Aura
    // covers SharedModules Swift/ObjC gates, NativeDev covers the Developer
    // row provider, and the generic router covers everything else.
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRSettingsRowsNativeEnsureHooksInstalled();
    WAGRReinstallPersistedHooks();
}

@end
