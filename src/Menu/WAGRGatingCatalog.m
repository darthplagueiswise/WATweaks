// WAGRGatingCatalog.m
// ─────────────────────────────────────────────────────────────────────────────
// Curated catalog of gates by area. Every entry here was sourced from static
// analysis of the WhatsApp 26.19.10 main binary and SharedModules dylib —
// see docs/gating_dump.md for the methodology. The catalog deliberately
// *excludes* gates we have not confirmed as ObjC-callable on this build,
// because surfacing a non-functional toggle is worse than not surfacing it.
//
// How to add a new gate
// ─────────────────────
// Append a row to `entriesForArea:` matching the area. The fields are:
//
//   className       — the runtime class that owns the method (use the
//                     mangled Swift name like _TtC6WAAura... when the gate
//                     lives on a Swift class)
//   selector        — the @selector name as a string
//   isClassMethod   — YES for +class methods, NO for -instance methods
//   title           — short user-facing label
//   desc            — one-line explanation of what the gate controls
//   inverted        — YES for "shouldHide*" / "is*Disabled" gates where the
//                     UI toggle "show this" maps to gate returning NO
//   availabilityCls — optional class-presence gate; nil if always relevant
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRGatingCatalog.h"
#import <objc/runtime.h>

// ── WAGRGatingEntry ─────────────────────────────────────────────────────────
@implementation WAGRGatingEntry

+ (instancetype)entryWithClass:(NSString *)cls
                      selector:(NSString *)sel
                 isClassMethod:(BOOL)isClassMethod
                         title:(NSString *)title
                          desc:(NSString *)desc
                          area:(WAGRGatingArea)area
                      inverted:(BOOL)inverted
             availabilityClass:(NSString *)availabilityClass {
    WAGRGatingEntry *e = [self new];
    e->_className         = [cls copy];
    e->_selectorName      = [sel copy];
    e->_isClassMethod     = isClassMethod;
    e->_title             = [title copy];
    e->_desc              = [desc copy];
    e->_area              = area;
    e->_inverted          = inverted;
    e->_availabilityClass = [availabilityClass copy];
    return e;
}

@end

// ── Area metadata ───────────────────────────────────────────────────────────
NSString *WAGRGatingAreaTitle(WAGRGatingArea area) {
    switch (area) {
        case WAGRGatingAreaAura:         return @"WA Aura / Subscription";
        case WAGRGatingAreaLiquidGlass:  return @"Liquid Glass";
        case WAGRGatingAreaEvolveAbout:  return @"Evolve / About / Contacts";
        case WAGRGatingAreaContactsHub:  return @"Contacts Hub / Online";
        case WAGRGatingAreaPayments:     return @"Payments / PIX / UPI";
        case WAGRGatingAreaLinkedDevices:return @"Linked / Primary / Companion";
        case WAGRGatingAreaGroups:       return @"Groups / Group AB";
        case WAGRGatingAreaHiddenRows:   return @"Hidden UI Rows";
        case WAGRGatingAreaChat:         return @"Chat Screen";
        case WAGRGatingAreaCall:         return @"Calls";
        case WAGRGatingAreaSettingsRows: return @"Settings Entry Points";
        case WAGRGatingAreaDeveloper:    return @"Developer / Dogfood";
        case WAGRGatingAreaAI:           return @"AI / Meta AI";
        case WAGRGatingAreaPrivacy:      return @"Privacy / Username";
        case WAGRGatingAreaCount:        return @"";
    }
    return @"";
}

NSString *WAGRGatingAreaIconName(WAGRGatingArea area) {
    switch (area) {
        case WAGRGatingAreaAura:         return @"star.circle.fill";
        case WAGRGatingAreaLiquidGlass:  return @"drop.fill";
        case WAGRGatingAreaEvolveAbout:  return @"person.crop.circle.badge.plus";
        case WAGRGatingAreaContactsHub:  return @"person.2.circle.fill";
        case WAGRGatingAreaPayments:     return @"creditcard.fill";
        case WAGRGatingAreaLinkedDevices:return @"link.circle.fill";
        case WAGRGatingAreaGroups:       return @"person.3.fill";
        case WAGRGatingAreaHiddenRows:   return @"eye.slash.fill";
        case WAGRGatingAreaChat:         return @"bubble.left.and.bubble.right.fill";
        case WAGRGatingAreaCall:         return @"phone.fill";
        case WAGRGatingAreaSettingsRows: return @"slider.horizontal.3";
        case WAGRGatingAreaDeveloper:    return @"chevron.left.forwardslash.chevron.right";
        case WAGRGatingAreaAI:           return @"sparkles";
        case WAGRGatingAreaPrivacy:      return @"lock.shield.fill";
        case WAGRGatingAreaCount:        return @"";
    }
    return @"";
}

NSString *WAGRGatingAreaSubtitle(WAGRGatingArea area) {
    switch (area) {
        case WAGRGatingAreaAura:
            return @"App themes, app icons, ringtones, subscription benefits";
        case WAGRGatingAreaLiquidGlass:
            return @"WAAB-first Liquid Glass toggles with WDSLiquidGlass aliases";
        case WAGRGatingAreaEvolveAbout:
            return @"About/Me tab, profile mood, contact card bubbles and Contacts Hub links";
        case WAGRGatingAreaContactsHub:
            return @"Recently-online contacts hub, favorites carousel and presence gates";
        case WAGRGatingAreaPayments:
            return @"Payments, PIX, UPI, passkey and Meta Pay Settings gates";
        case WAGRGatingAreaLinkedDevices:
            return @"Linked-device, companion, primary-device and iPad-as-primary gates";
        case WAGRGatingAreaGroups:
            return @"Group history, group status and group AB properties";
        case WAGRGatingAreaHiddenRows:
            return @"Reveals UI elements WhatsApp hides by feature flag";
        case WAGRGatingAreaChat:
            return @"Chat composer, reactions tray, side-chat overlay";
        case WAGRGatingAreaCall:
            return @"Call buttons, lightweight call dropdown, group call pickers";
        case WAGRGatingAreaSettingsRows:
            return @"Only native SettingsView row entry points; feature gates live in feature menus";
        case WAGRGatingAreaDeveloper:
            return @"Native dev menu, employee/internal gates, debug overlays";
        case WAGRGatingAreaAI:
            return @"Meta AI, incognito mode, AI subscription gates";
        case WAGRGatingAreaPrivacy:
            return @"Username row, passkey, privacy comparison screen";
        case WAGRGatingAreaCount:
            return @"";
    }
    return @"";
}

// ── Override key formatter ──────────────────────────────────────────────────
// Identical to the format used by WAGRObjCHookRouter so the menu and the
// router cooperate on the same NSUserDefaults keys.
NSString *WAGROverrideKeyFor(NSString *className, NSString *selectorName, BOOL isClassMethod) {
    NSString *kind = isClassMethod ? @"class" : @"inst";
    return [NSString stringWithFormat:@"wagr.override|objc|%@|%@|%@",
            className, kind, selectorName];
}

// ── The catalog itself ──────────────────────────────────────────────────────
// The current population is deliberately WAAB-first for UI/Settings rows.
// SharedModules confirms that the real WA Plus layer is split between:
//   • WAABProperties / FOAWAABPropertiesImpl AB flags
//   • WAAuraGating Swift classes in SharedModules
//   • native Settings row insertion flow
// So the menu surfaces WAAB flags that actually make rows appear, plus the
// few ObjC-visible Swift accessors FLEX showed in WAAuraGating.

static WAGRGatingEntry *E(NSString *cls, NSString *sel, BOOL meta,
                          NSString *title, NSString *desc,
                          WAGRGatingArea area, BOOL inverted) {
    return [WAGRGatingEntry entryWithClass:cls
                                  selector:sel
                             isClassMethod:meta
                                     title:title
                                      desc:desc
                                      area:area
                                  inverted:inverted
                         availabilityClass:nil];
}

static WAGRGatingEntry *WAAB(NSString *flag, NSString *title, NSString *desc,
                             WAGRGatingArea area, BOOL inverted) {
    return E(@"WAABProperties", flag, NO, title, desc, area, inverted);
}

static BOOL WAGRAuraRuntimeSelectorIsNegative(NSString *selectorName) {
    NSString *lower = selectorName.lowercaseString ?: @"";
    if ([lower containsString:@"killswitch_disabled"] ||
        [lower containsString:@"kill_switch_disabled"]) return NO;
    if ([lower hasSuffix:@"disabled"] || [lower containsString:@"disabledfor"]) return YES;
    return [lower containsString:@"killswitch"] ||
           [lower containsString:@"kill_switch"] ||
           [lower containsString:@"killswitchactive"] ||
           [lower containsString:@"block"];
}

static NSArray<WAGRGatingEntry *> *entries_Aura(void) {
    NSMutableArray<WAGRGatingEntry *> *a = [NSMutableArray array];

    // WAAB gates: these are the flags that unlock the Settings row and the
    // Aura/WA Plus surfaces before the Swift providers matter.
    [a addObjectsFromArray:@[
        WAAB(@"aura_enabled", @"Aura master gate", @"Main AB flag for Aura / WA Plus surfaces.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_settings_row_enabled", @"Subscriptions Settings row", @"Lets WhatsApp consider the Subscriptions / WA Plus Settings row.", WAGRGatingAreaAura, NO),
        WAAB(@"wa_subscriptions_entry_point_settings_enabled", @"Subscriptions entry point", @"Enables the Settings entry point used by the native WA Plus flow.", WAGRGatingAreaAura, NO),
        WAAB(@"wa_subscriptions_settings_green_dot_enabled", @"Subscriptions green dot", @"Surfaces the notification dot for the subscriptions Settings row.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_subscription_simulation_enabled", @"Aura simulation mode", @"Local AB flag used by Aura gating code paths.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_logging_enabled", @"Aura logging", @"Enables Aura logging paths for diagnostics.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_kill_switch", @"Disable Aura kill switch", @"Inverted: switch ON writes the physical gate to NO.", WAGRGatingAreaAura, YES),
        WAAB(@"aura_premium_stickers_killswitch", @"Disable premium stickers kill switch", @"Inverted: switch ON writes the physical gate to NO.", WAGRGatingAreaAura, YES),
        WAAB(@"aura_stickers_old_client_block_enabled", @"Disable old-client sticker block", @"Inverted: switch ON writes the physical block gate to NO.", WAGRGatingAreaAura, YES),

        WAAB(@"aura_app_icon_enabled", @"App icons gate", @"Enables the Aura app-icons feature family.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_icon_benefit_active", @"App icons benefit", @"Marks the app-icons benefit as active through WAAB.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_icon_multi_account_support", @"App icons multi-account", @"Enables Aura app icon support for multi-account surfaces.", WAGRGatingAreaAura, NO),

        WAAB(@"aura_app_themes_enabled", @"App themes gate", @"Enables Aura app themes.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_themes_benefit_active", @"App themes benefit", @"Marks the app-themes benefit as active through WAAB.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_themes_chat_checkmark_themed_enabled", @"Themed chat checkmarks", @"Enables themed chat checkmark UI.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_themes_new_selection_flow_enabled", @"New theme selection flow", @"Enables the newer Aura app-theme picker flow.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_themes_share_extension_themed_enabled", @"Share extension theming", @"Allows Aura themes to affect share-extension surfaces.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_themes_status_ring_enabled", @"Themed status ring", @"Enables status-ring theming.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_app_themes_illustration_lottie_enabled", @"Theme illustrations", @"Enables Aura Lottie illustration assets.", WAGRGatingAreaAura, NO),

        WAAB(@"aura_ringtones_enabled", @"Ringtones gate", @"Enables the Aura ringtones feature family.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_ringtones_benefit_active", @"Ringtones benefit", @"Marks ringtone benefit as active through WAAB.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_ringtones_per_chat_enabled", @"Per-chat ringtones", @"Enables per-chat ringtone surfaces.", WAGRGatingAreaAura, NO),
        WAAB(@"wa_plus_custom_ringtones", @"WA Plus custom ringtones", @"WA Plus custom ringtone entitlement/surface string observed in main binary.", WAGRGatingAreaAura, NO),
        WAAB(@"meta_subs_benefit_wa_ringtones_upsell", @"Ringtones upsell", @"Meta Subscriptions WA ringtones upsell gate.", WAGRGatingAreaAura, NO),
        WAAB(@"no_premium_ringtones_available", @"Disable no-ringtones empty state", @"Inverted: prevents the no-premium-ringtones state when ON.", WAGRGatingAreaAura, YES),
        WAAB(@"inapp_notification_personalized_ringtone_fix_enabled", @"Personalized ringtone fix", @"Personalized ringtone notification fix gate.", WAGRGatingAreaAura, NO),

        WAAB(@"aura_stickers_enabled", @"Stickers gate", @"Enables Aura sticker surfaces.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_stickers_benefit_active", @"Stickers benefit", @"Marks stickers benefit as active through WAAB.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_stickers_overlay_animation_enabled", @"Sticker overlay animation", @"Enables premium sticker overlay animations.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_painted_door_stickers_enabled", @"Painted-door stickers", @"Enables painted-door sticker surfaces.", WAGRGatingAreaAura, NO),

        WAAB(@"aura_pinned_chats_enabled", @"Pinned chats gate", @"Enables extended/premium pinned chats.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_pinned_chats_benefit_active", @"Pinned chats benefit", @"Marks pinned-chats benefit as active.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_pinned_chats_targeted_nux_force", @"Pinned chats NUX", @"Forces the targeted NUX for pinned chats.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_enhanced_lists_enabled", @"Enhanced lists gate", @"Enables enhanced lists surfaces.", WAGRGatingAreaAura, NO),
        WAAB(@"aura_enhanced_lists_benefit_active", @"Enhanced lists benefit", @"Marks enhanced-lists benefit as active.", WAGRGatingAreaAura, NO),

        WAAB(@"ai_subscription_enabled", @"AI subscription gate", @"Enables AI subscription entry points.", WAGRGatingAreaAura, NO),
        WAAB(@"ai_subscription_imagine_intent_enabled", @"AI subscription Imagine", @"Enables Imagine intent for AI subscription paths.", WAGRGatingAreaAura, NO),
        WAAB(@"isEligibleForSubscriptions", @"Eligible for subscriptions", @"WAAB getter used by subscriptions gating.", WAGRGatingAreaAura, NO),
        WAAB(@"isExpandedFormattingPlusEnabled", @"Expanded formatting plus", @"Enables plus-formatting gate used by subscription UI.", WAGRGatingAreaAura, NO),
        WAAB(@"isAppIconsBenefitActive", @"App-icons benefit getter", @"WAAB getter for app-icons benefit active state.", WAGRGatingAreaAura, NO),
        WAAB(@"isAppThemesBenefitActive", @"App-themes benefit getter", @"WAAB getter for app-themes benefit active state.", WAGRGatingAreaAura, NO),
        WAAB(@"isEnhancedListsBenefitActive", @"Enhanced-lists benefit getter", @"WAAB getter for enhanced-lists benefit active state.", WAGRGatingAreaAura, NO),
        WAAB(@"isExtendedPinnedChatBenefitActive", @"Pinned-chat benefit getter", @"WAAB getter for extended pinned-chat benefit active state.", WAGRGatingAreaAura, NO),
        WAAB(@"isRingtonesBenefitActive", @"Ringtones benefit getter", @"WAAB getter for ringtone benefit active state.", WAGRGatingAreaAura, NO),
        WAAB(@"isStickersBenefitActive", @"Stickers benefit getter", @"WAAB getter for stickers benefit active state.", WAGRGatingAreaAura, NO),
        WAAB(@"isSubscribedToAiBenefit", @"AI benefit getter", @"WAAB getter for AI benefit subscription state.", WAGRGatingAreaAura, NO),
        WAAB(@"isAISubscriptionEnabled", @"AI subscription getter", @"WAAB getter for AI subscription enabled state.", WAGRGatingAreaAura, NO),
    ]];

    // FLEX/SharedModules visible WAAuraGating accessors. These are not the
    // primary Settings-row path; they are exposed for diagnostics and targeted
    // runtime overrides when the Swift class is loaded.
    NSArray<NSString *> *swiftClasses = @[@"WAAuraGating", @"WAAuraGating.AuraGating",
                                       @"_TtC12WAAuraGating20GatedBenefitProvider",
                                       @"_TtC12WAAuraGating25GatedSubscriptionProvider"];
    NSArray<NSString *> *selectors = @[@"isEnabled", @"isUserEligible", @"isSettingsRowEnabled",
                                    @"isLoggingEnabled", @"isKillSwitchActive",
                                    @"isAppearanceSettingsEnabled", @"isAppIconsEnabled",
                                    @"isAppIconsBenefitActive", @"isAppThemesEnabled",
                                    @"isAppThemesBenefitActive", @"isRingtonesEnabled",
                                    @"isRingtonesBenefitActive", @"isStickersEnabled",
                                    @"isStickersBenefitActive", @"isEnhancedListsBenefitActive",
                                    @"isExtendedPinnedChatBenefitActive", @"isUserSubscribed"];
    for (NSString *cls in swiftClasses) {
        for (NSString *sel in selectors) {
            BOOL inv = WAGRAuraRuntimeSelectorIsNegative(sel);
            [a addObject:E(cls, sel, NO, [NSString stringWithFormat:@"%@ -%@", cls, sel],
                          @"SharedModules WAAuraGating runtime accessor observed through FLEX.",
                          WAGRGatingAreaAura, inv)];
        }
    }
    return a;
}

static NSArray<WAGRGatingEntry *> *entries_SettingsRows(void) {
    return @[
        WAAB(@"lists_feature_enabled", @"Lists row", @"SettingsView_ListCell / lists feature row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"lists_sync_enabled", @"Lists sync", @"Companion sync support for Lists Settings row.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"call_favorites_enabled_companions", @"Favorites row", @"SettingsView_FavoritesCell companion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"events_global_list", @"Events row", @"SettingsView_EventsCell global list gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"waffle_mobile_companions_enabled", @"WAFFLE row", @"SettingsView_WAFFLEHomeCell main companion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"waffle_enabled_for_unlinked_users", @"WAFFLE unlinked users", @"Secondary WAFFLE Settings-row eligibility flag.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"waffle_foa_to_wa_linking_enabled", @"WAFFLE FOA→WA linking", @"FOA linking gate for WAFFLE Settings row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"isPAAEligibleForWaffle", @"PAA eligible for WAFFLE", @"Eligibility getter used together with waffle_mobile_companions_enabled.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"sections_in_help_menu", @"Help menu sections", @"Send feedback / report bug / internal help sections.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_threads_bookmarks_enabled", @"Threads bookmark", @"SettingsView_ThreadsBookmark gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bookmark_sk_overlay_enabled", @"FOA bookmark overlay", @"Overlay support for FOA bookmarks.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bridges_bookmark_meta_horizon", @"Meta Horizon bookmark", @"SettingsView_MetaHorizonBookmark gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bridges_bookmarks_design_update_enabled", @"FOA bookmark redesign", @"Design update gate for FOA bridge bookmarks.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ai_rich_response_vibes_promotion_enabled", @"Vibes bookmark", @"SettingsView_VibesBookmark / promotion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ai_rich_response_c50_promotion_enabled", @"C50 promotion", @"AI rich response C50 promotion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"premium_blue_enabled", @"Premium Blue row", @"Premium/Blue Settings surface gate.", WAGRGatingAreaAura, NO),
        WAAB(@"ios_contacts_surface_is_enabled", @"Contacts surface", @"Hidden Contacts Settings surface gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_new_user_checklist_enabled", @"Me tab checklist", @"New-user checklist under Me/Settings tab.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_share_updates_enabled", @"Me tab share updates", @"Share-updates UI under Me/Settings tab.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"me_tab_settings_header_enabled", @"Me tab Settings header", @"Header experiment for Me tab / Settings.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"xfam_lg_switcher_m2_me_tab_enabled", @"Xfam account switcher", @"Me-tab account switcher gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"sg_ios_multi_account_enabled", @"Multi-account", @"Multi-account gate that can replace Settings tab icon with profile switcher.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"wa_xfam_ios_switcher_multiaccount_enabled", @"XFAM multi-account switcher", @"XFAM switcher multi-account gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"foa_bridges_account_switcher_ios_enabled", @"FOA account switcher", @"FOA bridges account switcher gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"deletion_reason_multi_account_enabled", @"Multi-account deletion reason", @"Companion multi-account gate observed in Settings bundle.", WAGRGatingAreaEvolveAbout, NO),

        // Payments / PIX / UPI. Static strings near WASettingsViewController show
        // SettingsView_PaymentsCell plus addPaymentsRowToSection:,
        // createPaymentRowIfNeeded: and showBRConsumerPaymentsHome.
        WAAB(@"br_consumer_payments_home_enabled", @"Payments row", @"SettingsView_PaymentsCell / Brazil consumer payments home.", WAGRGatingAreaPayments, NO),
        WAAB(@"br_consumer_paymentshome_enabled", @"Payments home alt gate", @"Alternate spelling observed near payments home code paths.", WAGRGatingAreaPayments, NO),
        WAAB(@"payments_home_revamp_m1_enabled", @"Payments home revamp M1", @"Payments home revamp gate.", WAGRGatingAreaPayments, NO),
        WAAB(@"payments_home_revamp_landing_screen_enabled", @"Payments landing screen", @"Landing-screen gate for payments home revamp.", WAGRGatingAreaPayments, NO),
        WAAB(@"payments_home_ui_updates_enabled", @"Payments UI updates", @"WAPaymentsShared extension getter for Settings/home UI updates.", WAGRGatingAreaPayments, NO),
        WAAB(@"payment_settings_add_bank_account_row", @"Add bank account row", @"PaymentSettingsView_AddAccountCell / bank account row.", WAGRGatingAreaPayments, NO),
        WAAB(@"payment_settings_add_upi_number_row", @"Add UPI number row", @"PaymentSettingsView UPI number row.", WAGRGatingAreaPayments, NO),
        WAAB(@"payment_settings_add_bank_banner", @"Payment bank banner", @"Bank-add banner inside Payment Settings.", WAGRGatingAreaPayments, NO),
        WAAB(@"payment_settings_invite_others_row", @"Payments invite row", @"PaymentSettingsView_InviteOthers row.", WAGRGatingAreaPayments, NO),
        WAAB(@"payment_settings_remove_payment_info_row", @"Remove payment info row", @"PaymentSettingsView_RemovePaymentsInfo row.", WAGRGatingAreaPayments, NO),
        WAAB(@"br_payments_pix_native_enabled", @"PIX native payments", @"Brazil PIX native payments gate.", WAGRGatingAreaPayments, NO),
        WAAB(@"br_payments_pix_groups_enabled", @"PIX groups", @"PIX payments in group surfaces.", WAGRGatingAreaPayments, NO),
        WAAB(@"br_p2p_add_pix_key_from_payment_settings", @"Add PIX key from Settings", @"Allows adding PIX key from Payment Settings.", WAGRGatingAreaPayments, NO),
        WAAB(@"br_payment_smb_connect_to_bank_enabled", @"SMB connect to bank", @"Business payment bank-linking Settings gate.", WAGRGatingAreaPayments, NO),
        WAAB(@"enable_payment_passkey", @"Payment passkey", @"Passkey gate used by payment settings/auth paths.", WAGRGatingAreaPayments, NO),
        WAAB(@"br_payments_passkey_enable", @"BR payments passkey", @"Brazil payments passkey gate.", WAGRGatingAreaPayments, NO),

        // Linked-device / primary-device support. These gates matter because
        // several Settings rows are hidden differently on companion devices or
        // require primary-device sync support before they render.
        WAAB(@"ios_linked_devices_empty_states_ui_refresh_enabled", @"Linked devices UI refresh", @"Linked Devices empty-state UI refresh gate.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"linked_devices_send_link_cta_ios", @"Linked devices send-link CTA", @"Linked Devices send-link CTA gate.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"linked_devices_apple_watch", @"Linked Apple Watch", @"Linked-device Apple Watch gate.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"md_linked_devices_badging_journey", @"Linked devices badging", @"MD linked-devices badging journey.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"companion_support_enabled", @"Companion support", @"Generic companion-support gate used in Settings-related flows.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"companion_contact_change_enabled", @"Companion contact changes", @"Allows contact-change support on companion devices.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"companion_lid_contact_change_enabled", @"Companion LID contact changes", @"LID contact-change support on companions.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"native_contacts_primary_allows_mutations_from_companions", @"Primary allows companion mutations", @"Primary-device contacts gate that affects companion Settings behavior.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"primary_lists_support", @"Primary Lists support", @"Primary-device Lists sync support.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"primary_favorites_sync_support", @"Primary Favorites support", @"Primary-device Favorites sync support.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"username_enabled_on_companion", @"Username on companion", @"Username row support on companion devices.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"enable_status_on_companion", @"Status on companion", @"Status feature support on companion devices.", WAGRGatingAreaLinkedDevices, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_HiddenRows(void) {
    return @[
        E(@"WAContactInfoTableViewController", @"isAudioCallButtonHidden", NO, @"Show audio call button", @"Inverted hidden-row selector. Switch ON returns NO.", WAGRGatingAreaHiddenRows, YES),
        E(@"WAContactInfoTableViewController", @"isVideoCallButtonHidden", NO, @"Show video call button", @"Inverted hidden-row selector. Switch ON returns NO.", WAGRGatingAreaHiddenRows, YES),
        E(@"WAContactInfoTableViewController", @"isProfilePictureHidden", NO, @"Show profile picture", @"Inverted hidden-row selector. Switch ON returns NO.", WAGRGatingAreaHiddenRows, YES),
        WAAB(@"visible_message_drop_placeholder_enabled_internal_only", @"Message drop placeholder", @"Internal-only hidden message placeholder gate.", WAGRGatingAreaHiddenRows, NO),
        WAAB(@"verified_badge_in_chats_list_enabled", @"Verified badge in chat list", @"Surfaces verified badge UI in chat list.", WAGRGatingAreaHiddenRows, NO),
        WAAB(@"channels_verified_badge_in_compact_inbox_enabled", @"Verified channel badge", @"Surfaces verified badge UI for channels in compact inbox.", WAGRGatingAreaHiddenRows, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_Developer(void) {
    return @[
        E(@"_TtC15WADebugMenuMain17DebugMenuProvider", @"isDebugMenuAllowed", NO, @"Native Developer menu", @"Allows WhatsApp's native Developer row to appear.", WAGRGatingAreaDeveloper, NO),
        E(@"_TtC15WADebugMenuMain17DebugMenuProvider", @"isDebugMenuShortcutEnabled", NO, @"Developer shortcut", @"Allows the native Developer shortcut chip.", WAGRGatingAreaDeveloper, NO),
        E(@"WAServerProperties", @"isInternalUser", YES, @"WAServerProperties internal user", @"Primary confirmed gate: +isInternalUser. WAServerProperties is configured from WAContextMain via +setUserContext:/+configureUserContext:.", WAGRGatingAreaDeveloper, NO),
        WAAB(@"mobile_config_debug_internal", @"MobileConfig debug internal", @"Internal MobileConfig debug gate.", WAGRGatingAreaDeveloper, NO),
        WAAB(@"dogfooder_diagnostics", @"Dogfooder diagnostics", @"Dogfood diagnostics flag.", WAGRGatingAreaDeveloper, NO),
        WAAB(@"ios_internal_hall_enabled", @"Internal hall", @"Internal hallway/debug surface gate.", WAGRGatingAreaDeveloper, NO),
        WAAB(@"is_internal_tester", @"Internal tester", @"WAAB internal tester flag.", WAGRGatingAreaDeveloper, NO),
        WAAB(@"sections_in_help_menu", @"Help developer sections", @"Surfaces internal sections inside Help menu.", WAGRGatingAreaDeveloper, NO),
        WAAB(@"enableEphemeralMessagesDebugOptions", @"Ephemeral debug options", @"Debug options for disappearing messages.", WAGRGatingAreaDeveloper, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_AI(void) {
    return @[
        WAAB(@"ai_meta_ai_in_app_tab_main_gate_enabled", @"Meta AI tab", @"Main gate for Meta AI tab.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_home_in_tab_main_gate_enabled", @"AI Home tab", @"AI home in-tab gate.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_home_redesign_enabled", @"AI Home redesign", @"New AI Home design gate.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_incognito_mode_enabled", @"AI incognito mode", @"Main AI incognito mode gate.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_side_chat_enabled", @"AI side chat", @"Side-chat entry point for AI.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_chat_threads_enabled", @"AI chat threads", @"Main AI chat threads gate.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_chat_threads_infra_enabled", @"AI thread infra", @"Infrastructure gate for AI threads.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_chat_thread_capability_enabled", @"AI thread capability", @"Capability gate for AI threads.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_hatch_integration_enabled", @"AI Hatch", @"Hatch integration gate.", WAGRGatingAreaAI, NO),
        WAAB(@"ai_imagine_in_media_editor_enabled", @"Imagine in editor", @"Imagine entry in media editor.", WAGRGatingAreaAI, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_Privacy(void) {
    return @[
        WAAB(@"defense_mode_available", @"Defense Mode", @"Defense mode availability gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"passkey_login", @"Passkey login", @"Passkey login gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"multiple_passkeys_delete_v2_enabled", @"Multiple passkeys delete v2", @"Passkey management gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"username_suggestions_enabled", @"Username suggestions", @"Username suggestions gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"username_key_redesign_enabled", @"Username redesign", @"Username key redesign gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"username_enabled_on_companion", @"Username companion", @"Username on companion gate.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isUsernameExperienceEnabled", NO, @"Runtime: username experience", @"WAUsernameGatingService instance getter from WAContextMain usernameGatingService.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isEligibleForActivation", NO, @"Runtime: username activation", @"Allows username activation when the gating service is queried.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"shouldShowUsernameRowOnCompanion", NO, @"Runtime: companion username row", @"Shows username row on companion devices.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"shouldShowReadOnlyBannerOnCompanion", NO, @"Runtime: companion read-only banner", @"Controls the companion read-only username banner.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isInReservationMode", NO, @"Runtime: username reservation", @"Username reservation mode gate.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isInCreationMode", NO, @"Runtime: username creation", @"Username creation mode gate.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isConsumerLinkingUpsellEnabled", NO, @"Runtime: linking upsell", @"Consumer linking upsell gate tied to usernames/FOA linking.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isLinkedAccountDirectReservationEnabled", NO, @"Runtime: linked direct reservation", @"Linked account direct username reservation gate.", WAGRGatingAreaPrivacy, NO),
        E(@"WAUsernameGatingService", @"isSMBLinkingEnabled", NO, @"Runtime: SMB linking", @"SMB username/account linking gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"allow_lid_contacts_privacy_settings", @"LID privacy settings", @"LID contacts privacy settings gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"allow_lid_contacts_calling", @"LID calling", @"LID contacts calling gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"privacy_setting_relay_all_calls", @"Relay all calls", @"Privacy relay-all-calls gate.", WAGRGatingAreaPrivacy, NO),
        WAAB(@"interop_client_ux_enabled", @"Interop UX", @"Interop client UX gate.", WAGRGatingAreaPrivacy, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_Call(void) {
    return @[
        WAAB(@"enable_calling_phone_number_privacy", @"Phone-number privacy", @"Calling phone-number privacy gate.", WAGRGatingAreaCall, NO),
        WAAB(@"enable_calling_username", @"Calling username", @"Username calling gate.", WAGRGatingAreaCall, NO),
        WAAB(@"calling_voicemail_enabled", @"Voicemail", @"Calling voicemail gate.", WAGRGatingAreaCall, NO),
        WAAB(@"enable_schedule_call_from_calls_tab", @"Schedule call from Calls tab", @"Scheduled-call entry in Calls tab.", WAGRGatingAreaCall, NO),
        WAAB(@"enable_scheduled_calls_v2_entry_points_creation", @"Scheduled calls v2", @"Scheduled calls creation entry points.", WAGRGatingAreaCall, NO),
        WAAB(@"enable_new_call_invite", @"New call invite", @"New call invite representation gate.", WAGRGatingAreaCall, NO),
        WAAB(@"enable_in_call_more_menu_ios", @"In-call more menu", @"iOS in-call more menu gate.", WAGRGatingAreaCall, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_Chat(void) {
    return @[
        WAAB(@"ai_translate_messages_enabled", @"Translate messages", @"AI translation in message flows.", WAGRGatingAreaChat, NO),
        WAAB(@"scheduled_messages_sender_enabled", @"Scheduled messages sender", @"Sender-side scheduled messages gate.", WAGRGatingAreaChat, NO),
        E(@"WAServerProperties", @"listMessageReceptionDisabled", YES, @"Enable list message reception", @"Inverted WAServerProperties gate: switch ON returns NO for +listMessageReceptionDisabled.", WAGRGatingAreaChat, YES),
        WAAB(@"scheduled_messages_receiver_enabled", @"Scheduled messages receiver", @"Receiver-side scheduled messages gate.", WAGRGatingAreaChat, NO),
        WAAB(@"poll_add_option_enabled", @"Poll add option", @"Poll editor add-option gate.", WAGRGatingAreaChat, NO),
        WAAB(@"poll_creator_edit_enabled", @"Poll creator edit", @"Poll creator edit gate.", WAGRGatingAreaChat, NO),
        WAAB(@"poll_end_time_enabled", @"Poll end time", @"Poll end-time gate.", WAGRGatingAreaChat, NO),
        WAAB(@"enable_sticker_lottie_reader_in_tray", @"Lottie stickers tray", @"Sticker tray Lottie reader gate.", WAGRGatingAreaChat, NO),
    ];
}


static NSArray<WAGRGatingEntry *> *entries_EvolveAbout(void) {
    return @[
        WAAB(@"evolve_about_m1_enabled", @"Evolve About M1", @"Main About Me / mood bubble creation and display gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"evolve_about_m1_receiver_enabled", @"Receiver surface", @"Receiver-side Evolve/About text-status surface.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"evolve_about_m1_receiver_for_new_surfaces_enabled", @"Receiver new surfaces", @"Receiver-side About surface for newer UI surfaces.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"evolve_about_migration_fix_enabled", @"Migration fix", @"Migration/fallback fix for Evolve About data.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"evolve_about_m2_contact_card_thought_bubble_enabled", @"Contact-card thought bubble", @"M2 thought bubble on contact card/profile surfaces.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"about_creation_sheet", @"About creation sheet", @"Enables the creation sheet for About/Mood updates.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"about_emoji_badge_in_group_sender_name_enabled", @"Emoji badge in group sender", @"Shows About emoji badge near group sender names.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_evolution_contacts_list_item_migration", @"Contacts item migration", @"Evolution contacts-list item migration gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_evolution_contacts_list_item_migration_part_2", @"Contacts item migration 2", @"Second-stage contacts-list migration gate.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"default_profile_pics_m1", @"Default profile pics M1", @"Profile-picture visual refresh used near About/Mood surfaces.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"profile_header_blue_badge", @"Profile header blue badge", @"Profile-header badge gate used around new profile/about surfaces.", WAGRGatingAreaEvolveAbout, NO),

        // Me tab / tab_me chain. These are part of the About/Me surface and must
        // move together with Evolve About; otherwise the About bubble is enabled
        // but the Me-tab entry points/header/profile surfaces stay gated off.
        WAAB(@"me_tab_status_creation_enabled", @"Me tab status creation", @"Enables status/About creation from the Me tab.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"me_tab_self_status_viewing_enabled", @"Me tab self status", @"Allows viewing your own status/About surface from Me tab.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"me_tab_settings_title_enabled", @"Me tab Settings title", @"Enables the Me-tab Settings title variant.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"me_tab_profile_picture_entrypoint_enabled", @"Me tab profile photo entry", @"Shows the Me-tab profile-picture entry point.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"me_tab_profile_picture_abprop_sync_enabled", @"Me tab profile photo sync", @"Syncs profile-picture gate state through AB properties.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"me_tab_remove_privacy_button_enabled", @"Me tab privacy button", @"Enables the privacy/remove button used by the Me-tab profile surface.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"wa_account_switcher_settings_me_tab", @"Me tab account switcher", @"Enables the account switcher entry point in Settings/Me tab.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_username_findability_enabled", @"Me tab username findability", @"Enables username findability affordances from the Me tab.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_cover_photo_enabled", @"Me tab cover photo", @"Enables cover-photo support for the Me/About profile surface.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_cover_photo_default_state_enabled", @"Cover photo default state", @"Default-state gate for Me-tab cover photo.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_cover_photo_prefetch_enabled", @"Cover photo prefetch", @"Prefetches cover-photo data for the Me/About surface.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_me_tab_cover_photo_viewing_enabled", @"Cover photo viewing", @"Enables cover-photo viewing in the Me/About surface.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"ios_liquid_glass_fix_me_tab_profile_render_throttle_enabled", @"Me tab render throttle fix", @"Liquid Glass profile-render throttle fix tied to the Me tab.", WAGRGatingAreaEvolveAbout, NO),

        WAAB(@"client_profile_photo_sync_m1_sender", @"Profile photo sync sender", @"Sender side of client profile-photo sync M1.", WAGRGatingAreaEvolveAbout, NO),
        WAAB(@"client_profile_photo_sync_m1_receiver", @"Profile photo sync receiver", @"Receiver side of client profile-photo sync M1.", WAGRGatingAreaEvolveAbout, NO),
        E(@"WASettingsViewController", @"isEvolveAboutM1Enabled", NO, @"Settings About M1 method", @"Native method seen in WhatsApp Settings model.", WAGRGatingAreaEvolveAbout, NO),
        E(@"WAContextMain", @"isMeTabEnabled", NO, @"Runtime: Me tab enabled", @"WAContextMain/WAContext chain getter observed in the main exec; use with WAAB Me-tab flags.", WAGRGatingAreaEvolveAbout, NO),
        E(@"WAContext", @"isMeTabEnabled", NO, @"Runtime: WAContext Me tab enabled", @"WAContext-level Me-tab getter if the build exposes it.", WAGRGatingAreaEvolveAbout, NO),
        E(@"WASettingsViewController", @"isMeTabProfilePictureEntrypointEnabled", NO, @"Runtime: profile photo entry", @"Settings-side Me-tab profile-picture entry-point getter.", WAGRGatingAreaEvolveAbout, NO),
        E(@"WAContactInfoTableViewCell", @"isEvolveAboutReceiverAndNewSurfacesEnabled", NO, @"Contact cell receiver method", @"SharedModules contact-cell receiver/new-surface gate if present.", WAGRGatingAreaEvolveAbout, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_ContactsHub(void) {
    return @[
        WAAB(@"ios_contacts_surface_is_enabled", @"Contacts surface", @"Enables the Contacts section under the profile header in Settings.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contactshub_presence_status", @"Contacts Hub presence", @"Presence/online-status support for WAContactsHub.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contactshub_hide_module2_on_lness_is_enabled", @"Keep recently-online module visible", @"Inverted: switch ON returns NO for the hide-module gate.", WAGRGatingAreaContactsHub, YES),
        WAAB(@"new_chat_suggestions_recently_online_improvements_enabled", @"Recently-online improvements", @"Recently-online ranking/suggestion improvements.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"new_chat_suggestions_new_to_wa_and_recently_online_split_sections_enabled", @"Split new/recently online", @"Splits New to WhatsApp and Recently Online suggestion sections.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestion_on_chat_picker_enabled", @"Contact suggestions picker", @"Contact suggestions in the new chat picker.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestions_eligibility_expansion_enabled", @"Eligibility expansion", @"Expands contact-suggestion eligibility.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestions_m1_variant_enabled", @"Suggestions M1", @"M1 variant for contact suggestions.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestions_rai_inventory_expansion_enabled", @"RAI inventory expansion", @"Expands inventory used by contact suggestions.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestion_ml_model_enabled", @"ML model", @"ML model for contact suggestions.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestion_qpl_enabled", @"QPL logging", @"QPL logging for contact suggestions.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_contact_suggestion_presence_prefetch_enabled", @"Presence prefetch", @"Prefetches presence for contact suggestions / recently online.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"new_chat_picker_suggestions_priority_jids_enabled", @"Priority JIDs", @"Allows priority JIDs in new chat suggestions.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"new_chat_picker_suggestions_exclude_jids_enabled", @"Exclude JIDs", @"Allows exclude JIDs in new chat suggestions.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"chat_list_contact_suggestions_enabled", @"Chat list suggestions", @"Contact suggestions on the chat list.", WAGRGatingAreaContactsHub, NO),
        WAAB(@"ios_show_contact_suggestions_when_contacts_synced", @"Show when contacts synced", @"Shows contact suggestions when contacts are already synced.", WAGRGatingAreaContactsHub, NO),
        E(@"_TtC13WAContactsHub25ContactsHubViewController", @"hasFavorites", NO, @"Runtime: has favorites", @"WAContactsHub runtime property if exposed through ObjC.", WAGRGatingAreaContactsHub, NO),
        E(@"_TtC13WAContactsHub28AllContactsSectionDataSource", @"sectionActive", NO, @"Runtime: all contacts active", @"AllContacts section activity gate if exposed through ObjC.", WAGRGatingAreaContactsHub, NO),
        E(@"_TtC13WAContactsHub32FavoriteContactsPresenceProvider", @"isFiltering", NO, @"Runtime: presence filtering", @"Presence/favorite provider runtime bool if exposed.", WAGRGatingAreaContactsHub, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_Payments(void) {
    return @[
        E(@"WAServerProperties", @"paymentsUPIOverdraftAccountEnabled", YES, @"Runtime: UPI overdraft", @"WAServerProperties class method visible in Flex; enables the UPI overdraft account gate.", WAGRGatingAreaPayments, NO),
        E(@"WASettingsViewController", @"showBRConsumerPaymentsHome", NO, @"Settings payment home", @"Native WASettingsViewController payment-home method.", WAGRGatingAreaPayments, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_LinkedDevices(void) {
    return @[
        WAAB(@"md_linked_devices_ui_refresh_enabled", @"MD linked UI refresh", @"Multi-device linked devices UI refresh gate.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"device_capabilities_sync_enabled", @"Device capabilities sync", @"Device capability sync gate.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"ipad_as_primary_enabled", @"iPad as primary", @"iPad-as-primary experiment gate.", WAGRGatingAreaLinkedDevices, NO),
        WAAB(@"wa_ipad_as_primary_killswitch_disabled", @"iPad primary killswitch disabled", @"Positive disabled-killswitch gate; switch ON writes physical YES.", WAGRGatingAreaLinkedDevices, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_Groups(void) {
    return @[
        WAAB(@"group_history_send_enabled", @"Group history send", @"Group history-send AB gate.", WAGRGatingAreaGroups, NO),
        WAAB(@"group_history_setting_ui_enabled", @"Group history UI", @"Group history Settings UI AB gate.", WAGRGatingAreaGroups, NO),
        E(@"WAServerProperties", @"frequentlyForwardedGroupSettingEnabled", YES, @"Runtime: forwarded group setting", @"WAServerProperties class method for the frequently-forwarded group setting.", WAGRGatingAreaGroups, NO),
        WAAB(@"group_status_enabled", @"Group status", @"Group Status feature gate.", WAGRGatingAreaGroups, NO),
        WAAB(@"group_status_setting_ui_enabled", @"Group status UI", @"Group Status settings UI gate.", WAGRGatingAreaGroups, NO),
        WAAB(@"allow_lid_contacts_add_to_group", @"LID contacts add to group", @"LID contacts add-to-group gate.", WAGRGatingAreaGroups, NO),
        WAAB(@"add_non_contacts_to_groups_enabled", @"Add non-contacts to groups", @"Non-contact group add gate.", WAGRGatingAreaGroups, NO),
        WAAB(@"allowNonAdminSubGroupCreation", @"Non-admin subgroup creation", @"Subgroup creation gate observed in main strings.", WAGRGatingAreaGroups, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_LiquidGlass(void) {
    return @[
        WAAB(@"ios_liquid_glass_enabled", @"Liquid Glass master", @"Main WAAB gate. Also aliases core WDSLiquidGlass runtime selectors.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_launched", @"Liquid Glass launched", @"Launch-state gate. Also aliases WDSLiquidGlass +hasLiquidGlassLaunched.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_media_m0", @"Media M0", @"WAAB + WDSLiquidGlass +isM0Enabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_media_editor_enabled", @"Media editor", @"Liquid Glass media editor gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_calling_improvement_enabled", @"Calling improvement", @"Liquid Glass calling improvement gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_workaround_attachment_tray", @"Attachment tray workaround", @"Attachment tray workaround gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m1", @"M1", @"WAAB + WDSLiquidGlass +isM1Enabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m_1_5", @"M1.5", @"WAAB + WDSLiquidGlass +isM1_5Enabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m_1_5_context_menu", @"M1.5 context menu", @"WAAB + WDSLiquidGlass +isM1_5ContextMenuEnabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_enable_new_chatbar_ux", @"New chatbar UX", @"WAAB + WDSLiquidGlass +isNewChatbarUXEnabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_chat_top_bar_m2_enabled", @"Chat top bar M2", @"WAAB + WDSLiquidGlass +isChatTopBarM2Enabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_text_layout_m2_enabled", @"Text layout M2", @"WAAB + WDSLiquidGlass +isTextLayoutM2Enabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m_2_action_tile", @"Action tile M2", @"WAAB + WDSLiquidGlass +isActionTileM2Enabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_unify_ui_refresh_enabled", @"Unify UI refresh", @"WAAB + WDSLiquidGlass +isUnifyUIRefreshEnabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_unify_navigation_bar_enabled", @"Unify navigation bar", @"WAAB + WDSLiquidGlass +isUnifyNavigationBarEnabled alias.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_native_sidebar_enabled", @"Native sidebar", @"WAAB + WDSLiquidGlass +isNativeSidebarEnabled alias.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isChatbarLowerBottomPaddingEnabled", YES, @"Runtime: chatbar lower padding", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"shouldUseNativeSwipeActions", YES, @"Runtime: native swipe actions", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isHidingBottomBarWorkaroundEnabled", YES, @"Runtime: bottom bar workaround", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isTopBarAppearanceWorkaroundEnabled", YES, @"Runtime: top bar workaround", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isFixesForOlderOSEnabled", YES, @"Runtime: older OS fixes", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isFixTabbarBadgeOffthreadEnabled", YES, @"Runtime: tab badge fix", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isContextMenuTransitionSafetyFixEnabled", YES, @"Runtime: context menu safety", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isFixContextMenuOnDisappearEnabled", YES, @"Runtime: context disappear fix", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isFixUpdatesTableDynamicColorEnabled", YES, @"Runtime: dynamic table color fix", @"WDSLiquidGlass runtime selector visible in Flex.", WAGRGatingAreaLiquidGlass, NO),
        E(@"WDSLiquidGlass", @"isCustomToolbarDisabledForLiquidGlass", YES, @"Runtime: keep custom toolbar", @"Inverted: switch ON returns NO for the disabled gate.", WAGRGatingAreaLiquidGlass, YES),
    ];
}


// ── WAGRGatingCatalog accessor ──────────────────────────────────────────────
@implementation WAGRGatingCatalog

+ (NSArray<WAGRGatingEntry *> *)entriesForArea:(WAGRGatingArea)area {
    NSArray<WAGRGatingEntry *> *raw = @[];
    switch (area) {
        case WAGRGatingAreaAura:         raw = entries_Aura();         break;
        case WAGRGatingAreaLiquidGlass:  raw = entries_LiquidGlass();  break;
        case WAGRGatingAreaEvolveAbout:  raw = entries_EvolveAbout();  break;
        case WAGRGatingAreaContactsHub:  raw = entries_ContactsHub();  break;
        case WAGRGatingAreaPayments:     raw = entries_Payments();     break;
        case WAGRGatingAreaLinkedDevices:raw = entries_LinkedDevices();break;
        case WAGRGatingAreaGroups:       raw = entries_Groups();       break;
        case WAGRGatingAreaHiddenRows:   raw = entries_HiddenRows();   break;
        case WAGRGatingAreaChat:         raw = entries_Chat();         break;
        case WAGRGatingAreaCall:         raw = entries_Call();         break;
        case WAGRGatingAreaSettingsRows: raw = entries_SettingsRows(); break;
        case WAGRGatingAreaDeveloper:    raw = entries_Developer();    break;
        case WAGRGatingAreaAI:           raw = entries_AI();           break;
        case WAGRGatingAreaPrivacy:      raw = entries_Privacy();      break;
        case WAGRGatingAreaCount:        raw = @[];                    break;
    }

    // Filter entries whose availabilityClass is set but not present in the
    // runtime. This prevents showing dead toggles for features that this
    // build of WhatsApp does not include.
    NSMutableArray *available = [NSMutableArray arrayWithCapacity:raw.count];
    for (WAGRGatingEntry *e in raw) {
        if (e.availabilityClass.length == 0) { [available addObject:e]; continue; }
        if (NSClassFromString(e.availabilityClass) != nil) [available addObject:e];
    }
    return available;
}

+ (NSUInteger)countForArea:(WAGRGatingArea)area {
    return [self entriesForArea:area].count;
}

@end
