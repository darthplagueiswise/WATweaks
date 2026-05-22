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
        case WAGRGatingAreaHiddenRows:   return @"Hidden UI Rows";
        case WAGRGatingAreaChat:         return @"Chat Screen";
        case WAGRGatingAreaCall:         return @"Calls";
        case WAGRGatingAreaSettingsRows: return @"Settings Rows";
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
            return @"M0/M1/M2 visual experiments, chat bar UX, composer";
        case WAGRGatingAreaHiddenRows:
            return @"Reveals UI elements WhatsApp hides by feature flag";
        case WAGRGatingAreaChat:
            return @"Chat composer, reactions tray, side-chat overlay";
        case WAGRGatingAreaCall:
            return @"Call buttons, lightweight call dropdown, group call pickers";
        case WAGRGatingAreaSettingsRows:
            return @"Hidden rows inside the Settings screen";
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
    return [lower containsString:@"killswitch"] ||
           [lower containsString:@"kill_switch"] ||
           [lower containsString:@"killswitchactive"] ||
           [lower containsString:@"kill"] ||
           [lower containsString:@"block"] ||
           [lower containsString:@"disabled"];
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
        WAAB(@"lists_sync_enabled", @"Lists sync", @"Companion sync support for Lists Settings row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"call_favorites_enabled_companions", @"Favorites row", @"SettingsView_FavoritesCell companion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"events_global_list", @"Events row", @"SettingsView_EventsCell global list gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"waffle_mobile_companions_enabled", @"WAFFLE row", @"SettingsView_WAFFLEHomeCell main companion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"waffle_enabled_for_unlinked_users", @"WAFFLE unlinked users", @"Secondary WAFFLE Settings-row eligibility flag.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"waffle_foa_to_wa_linking_enabled", @"WAFFLE FOA→WA linking", @"FOA linking gate for WAFFLE Settings row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"isPAAEligibleForWaffle", @"PAA eligible for WAFFLE", @"Eligibility getter used together with waffle_mobile_companions_enabled.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"aura_settings_row_enabled", @"Subscriptions / Aura row", @"SettingsView_SubscriptionsCell / Aura Settings row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"aura_enabled", @"Aura master for row", @"Required companion flag for Subscriptions / Aura row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"wa_subscriptions_entry_point_settings_enabled", @"Subscriptions Settings entry point", @"Entry-point flag for native subscription management.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"wa_subscriptions_settings_green_dot_enabled", @"Subscriptions green dot", @"Green dot / nudge for subscription Settings row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"sections_in_help_menu", @"Help menu sections", @"Send feedback / report bug / internal help sections.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_threads_bookmarks_enabled", @"Threads bookmark", @"SettingsView_ThreadsBookmark gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bookmark_sk_overlay_enabled", @"FOA bookmark overlay", @"Overlay support for FOA bookmarks.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bridges_bookmark_meta_horizon", @"Meta Horizon bookmark", @"SettingsView_MetaHorizonBookmark gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bridges_bookmarks_design_update_enabled", @"FOA bookmark redesign", @"Design update gate for FOA bridge bookmarks.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ai_rich_response_vibes_promotion_enabled", @"Vibes bookmark", @"SettingsView_VibesBookmark / promotion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ai_rich_response_c50_promotion_enabled", @"C50 promotion", @"AI rich response C50 promotion gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"premium_blue_enabled", @"Premium Blue row", @"Premium/Blue Settings surface gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ios_contacts_surface_is_enabled", @"Contacts surface", @"Hidden Contacts Settings surface gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ios_me_tab_new_user_checklist_enabled", @"Me tab checklist", @"New-user checklist under Me/Settings tab.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"ios_me_tab_share_updates_enabled", @"Me tab share updates", @"Share-updates UI under Me/Settings tab.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"me_tab_settings_header_enabled", @"Me tab Settings header", @"Header experiment for Me tab / Settings.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"xfam_lg_switcher_m2_me_tab_enabled", @"Xfam account switcher", @"Me-tab account switcher gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"sg_ios_multi_account_enabled", @"Multi-account", @"Multi-account gate that can replace Settings tab icon with profile switcher.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"wa_xfam_ios_switcher_multiaccount_enabled", @"XFAM multi-account switcher", @"XFAM switcher multi-account gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"foa_bridges_account_switcher_ios_enabled", @"FOA account switcher", @"FOA bridges account switcher gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"deletion_reason_multi_account_enabled", @"Multi-account deletion reason", @"Companion multi-account gate observed in Settings bundle.", WAGRGatingAreaSettingsRows, NO),

        // Payments / PIX / UPI. Static strings near WASettingsViewController show
        // SettingsView_PaymentsCell plus addPaymentsRowToSection:,
        // createPaymentRowIfNeeded: and showBRConsumerPaymentsHome.
        WAAB(@"br_consumer_payments_home_enabled", @"Payments row", @"SettingsView_PaymentsCell / Brazil consumer payments home.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"br_consumer_paymentshome_enabled", @"Payments home alt gate", @"Alternate spelling observed near payments home code paths.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payments_home_revamp_m1_enabled", @"Payments home revamp M1", @"Payments home revamp gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payments_home_revamp_landing_screen_enabled", @"Payments landing screen", @"Landing-screen gate for payments home revamp.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payments_home_ui_updates_enabled", @"Payments UI updates", @"WAPaymentsShared extension getter for Settings/home UI updates.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payment_settings_add_bank_account_row", @"Add bank account row", @"PaymentSettingsView_AddAccountCell / bank account row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payment_settings_add_upi_number_row", @"Add UPI number row", @"PaymentSettingsView UPI number row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payment_settings_add_bank_banner", @"Payment bank banner", @"Bank-add banner inside Payment Settings.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payment_settings_invite_others_row", @"Payments invite row", @"PaymentSettingsView_InviteOthers row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"payment_settings_remove_payment_info_row", @"Remove payment info row", @"PaymentSettingsView_RemovePaymentsInfo row.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"br_payments_pix_native_enabled", @"PIX native payments", @"Brazil PIX native payments gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"br_payments_pix_groups_enabled", @"PIX groups", @"PIX payments in group surfaces.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"br_p2p_add_pix_key_from_payment_settings", @"Add PIX key from Settings", @"Allows adding PIX key from Payment Settings.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"br_payment_smb_connect_to_bank_enabled", @"SMB connect to bank", @"Business payment bank-linking Settings gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"enable_payment_passkey", @"Payment passkey", @"Passkey gate used by payment settings/auth paths.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"br_payments_passkey_enable", @"BR payments passkey", @"Brazil payments passkey gate.", WAGRGatingAreaSettingsRows, NO),

        // Linked-device / primary-device support. These gates matter because
        // several Settings rows are hidden differently on companion devices or
        // require primary-device sync support before they render.
        WAAB(@"ios_linked_devices_empty_states_ui_refresh_enabled", @"Linked devices UI refresh", @"Linked Devices empty-state UI refresh gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"linked_devices_send_link_cta_ios", @"Linked devices send-link CTA", @"Linked Devices send-link CTA gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"linked_devices_apple_watch", @"Linked Apple Watch", @"Linked-device Apple Watch gate.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"md_linked_devices_badging_journey", @"Linked devices badging", @"MD linked-devices badging journey.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"companion_support_enabled", @"Companion support", @"Generic companion-support gate used in Settings-related flows.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"companion_contact_change_enabled", @"Companion contact changes", @"Allows contact-change support on companion devices.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"companion_lid_contact_change_enabled", @"Companion LID contact changes", @"LID contact-change support on companions.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"native_contacts_primary_allows_mutations_from_companions", @"Primary allows companion mutations", @"Primary-device contacts gate that affects companion Settings behavior.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"primary_lists_support", @"Primary Lists support", @"Primary-device Lists sync support.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"primary_favorites_sync_support", @"Primary Favorites support", @"Primary-device Favorites sync support.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"username_enabled_on_companion", @"Username on companion", @"Username row support on companion devices.", WAGRGatingAreaSettingsRows, NO),
        WAAB(@"enable_status_on_companion", @"Status on companion", @"Status feature support on companion devices.", WAGRGatingAreaSettingsRows, NO),
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
        E(@"WAServerProperties", @"isInternalUser", YES, @"Internal user", @"Confirmed class-method owner for internal user gate.", WAGRGatingAreaDeveloper, NO),
        E(@"WAServerProperties", @"graphQLEmployeeC1Disabled", YES, @"GraphQL employee C1", @"Inverted: switch ON returns NO for the disabled gate.", WAGRGatingAreaDeveloper, YES),
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
        WAAB(@"scheduled_messages_receiver_enabled", @"Scheduled messages receiver", @"Receiver-side scheduled messages gate.", WAGRGatingAreaChat, NO),
        WAAB(@"poll_add_option_enabled", @"Poll add option", @"Poll editor add-option gate.", WAGRGatingAreaChat, NO),
        WAAB(@"poll_creator_edit_enabled", @"Poll creator edit", @"Poll creator edit gate.", WAGRGatingAreaChat, NO),
        WAAB(@"poll_end_time_enabled", @"Poll end time", @"Poll end-time gate.", WAGRGatingAreaChat, NO),
        WAAB(@"enable_sticker_lottie_reader_in_tray", @"Lottie stickers tray", @"Sticker tray Lottie reader gate.", WAGRGatingAreaChat, NO),
    ];
}

static NSArray<WAGRGatingEntry *> *entries_LiquidGlass(void) {
    return @[
        WAAB(@"ios_liquid_glass_enabled", @"Liquid Glass enabled", @"Main Liquid Glass gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_launched", @"Liquid Glass launched", @"Launch gate for Liquid Glass surfaces.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m1", @"Liquid Glass M1", @"M1 experiment gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m_1_5", @"Liquid Glass M1.5", @"M1.5 experiment gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m_2_action_tile", @"M2 action tile", @"M2 action tile gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_m_2_chips", @"M2 chips", @"M2 chips gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_chat_top_bar_m2_enabled", @"Chat top bar M2", @"Liquid Glass chat top bar M2 gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_enable_new_chatbar_ux", @"New chatbar UX", @"New chatbar UX gate.", WAGRGatingAreaLiquidGlass, NO),
        WAAB(@"ios_liquid_glass_larger_composer", @"Larger composer", @"Liquid Glass larger composer gate.", WAGRGatingAreaLiquidGlass, NO),
    ];
}

// ── WAGRGatingCatalog accessor ──────────────────────────────────────────────
@implementation WAGRGatingCatalog

+ (NSArray<WAGRGatingEntry *> *)entriesForArea:(WAGRGatingArea)area {
    NSArray<WAGRGatingEntry *> *raw = @[];
    switch (area) {
        case WAGRGatingAreaAura:         raw = entries_Aura();         break;
        case WAGRGatingAreaLiquidGlass:  raw = entries_LiquidGlass();  break;
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
