// WAGRGateRegistry.m — provider definitions.
// ─────────────────────────────────────────────────────────────────────────────
// Featured selectors come from static analysis of SharedModules + WhatsApp
// (see docs/gating_dump.md). They are the names confirmed to exist in the
// shipped binary, surfaced in the UI as "the dial the user is looking for".
// Everything else discovered at runtime is reachable via "Runtime Avançado".
//
// Class fragment lists are intentionally tight. A broad fragment like
// "WA" would match thousands of unrelated classes; we keep the scan
// focused so the runtime browser opens fast even on a cold app.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRGateRegistry.h"

// ── WAGRGateFeaturedFlag ─────────────────────────────────────────────────────
@implementation WAGRGateFeaturedFlag
+ (instancetype)flagWithName:(NSString *)selectorName
                       title:(NSString *)title
                      detail:(NSString *)detail
                    inverted:(BOOL)inverted {
    WAGRGateFeaturedFlag *f = [self new];
    f.selectorName = [selectorName copy];
    f.title = [title copy];
    f.detail = [detail copy];
    f.inverted = inverted;
    return f;
}
@end

// ── WAGRGateProvider ─────────────────────────────────────────────────────────
@implementation WAGRGateProvider
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _concreteClassNames = @[];
    _classNameFragments = @[];
    _selectorTokens = @[];
    _featured = @[];
    _scanInstanceMethods = YES;
    _scanClassMethods = YES;
    _scanProperties = YES;
    return self;
}
@end

// ── Convenience builder ──────────────────────────────────────────────────────
static WAGRGateProvider *WAGRMakeProvider(NSString *pid,
                                          NSString *title,
                                          NSString *subtitle,
                                          NSString *icon,
                                          NSArray<NSString *> *concreteClasses,
                                          NSArray<NSString *> *fragments,
                                          NSArray<NSString *> *tokens,
                                          NSArray<WAGRGateFeaturedFlag *> *featured) {
    WAGRGateProvider *p = [WAGRGateProvider new];
    p.providerID = pid;
    p.title = title;
    p.subtitle = subtitle ?: @"";
    p.icon = icon ?: @"circle";
    p.concreteClassNames = concreteClasses ?: @[];
    p.classNameFragments = fragments ?: @[];
    p.selectorTokens = tokens ?: @[];
    p.featured = featured ?: @[];
    return p;
}

static inline WAGRGateFeaturedFlag *F(NSString *name, NSString *title, NSString *detail) {
    return [WAGRGateFeaturedFlag flagWithName:name title:title detail:detail inverted:NO];
}

static inline WAGRGateFeaturedFlag *FInv(NSString *name, NSString *title, NSString *detail) {
    return [WAGRGateFeaturedFlag flagWithName:name title:title detail:detail inverted:YES];
}

// ── Provider definitions ─────────────────────────────────────────────────────
@implementation WAGRGateRegistry

+ (NSArray<WAGRGateProvider *> *)allProviders {
    static NSArray<WAGRGateProvider *> *providers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        providers = @[
            // ── Server Properties ────────────────────────────────────────────
            // WAServerProperties has class methods (BOOL no-arg). Static dump
            // confirmed +isInternalUser plus three UPI/list/group switches
            // sharing one IMP — per-selector overrides handle that case
            // because dispatch is by selector, not by IMP.
            WAGRMakeProvider(@"server",
                @"WAServerProperties",
                @"Conta master gates: internal user, UPI, list message, group settings",
                @"server.rack",
                @[ @"WAServerProperties" ],
                @[ @"WAServerProperties", @"ServerProperties" ],
                @[],
                @[
                    F(@"isInternalUser",
                      @"Internal User",
                      @"+isInternalUser de WAServerProperties — destrava menu Developer e gates internos."),
                    F(@"paymentsUPIOverdraftAccountEnabled",
                      @"Payments UPI Overdraft Account",
                      @"UPI overdraft account opcional."),
                    F(@"listMessageReceptionDisabled",
                      @"List Message Reception Disabled",
                      @"Define recepção de list messages."),
                    F(@"frequentlyForwardedGroupSettingEnabled",
                      @"Frequently Forwarded Group Setting",
                      @"Gates de forward em grupos.")
                ]),

            // ── WAABProperties ───────────────────────────────────────────────
            // The single biggest provider. Featured rows cover the WAAB flags
            // we know the user wants to dial in; the runtime browser exposes
            // everything else.
            WAGRMakeProvider(@"waab",
                @"WAAB Properties",
                @"AB feature flags (WAABProperties + FOAWAABPropertiesImpl)",
                @"switch.2",
                @[ @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"WAABProperties", @"ABProperties", @"FOAWAABProperties" ],
                @[],
                @[
                    F(@"hasLiquidGlassLaunched",
                      @"LiquidGlass Launched",
                      @"Trava geral do LiquidGlass."),
                    F(@"ios_liquid_glass_enabled",
                      @"iOS LiquidGlass enabled",
                      @"Master da feature LiquidGlass."),
                    F(@"aura_enabled",
                      @"Aura enabled",
                      @"Master geral do WA Plus / Aura."),
                    F(@"aura_settings_row_enabled",
                      @"Aura Settings Row",
                      @"Linha de assinatura/Plus em Configurações."),
                    F(@"ios_contacts_surface_is_enabled",
                      @"Contacts Surface",
                      @"Contacts Hub e seções relacionadas."),
                    F(@"br_consumer_payments_home_enabled",
                      @"BR Payments Home",
                      @"Página de pagamentos para BR consumer."),
                    F(@"companion_support_enabled",
                      @"Companion Support",
                      @"Suporte a dispositivos vinculados primários.")
                ]),

            // ── LiquidGlass ──────────────────────────────────────────────────
            // Featured rows match the schema used by WhatsApp's own WAAB keys
            // for LiquidGlass milestones — the user can leave the master on
            // and selectively disable M1.5/M2.
            WAGRMakeProvider(@"liquidglass",
                @"LiquidGlass / WDS",
                @"Visual experiments (master + milestones M0..M2)",
                @"drop",
                @[ @"WDSLiquidGlass", @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"LiquidGlass", @"WDSLiquidGlass" ],
                @[ @"liquid", @"glass", @"wds", @"m1", @"m_1", @"m2", @"m_2" ],
                @[
                    F(@"ios_liquid_glass_enabled",      @"Master enabled",       @"WAAB master geral."),
                    F(@"ios_liquid_glass_launched",    @"Master launched",       @"Já lançou para o usuário."),
                    F(@"ios_liquid_glass_media_m0",    @"Milestone M0",          @"Media M0."),
                    F(@"ios_liquid_glass_m1",          @"Milestone M1",          @"Aparência M1."),
                    F(@"ios_liquid_glass_m_1_5",       @"Milestone M1.5",        @"Refinamentos M1.5."),
                    F(@"ios_liquid_glass_m_1_5_context_menu", @"M1.5 Context Menu", @"Menu de contexto M1.5."),
                    F(@"ios_liquid_glass_chat_top_bar_m2_enabled", @"M2 Chat Top Bar", @"Barra superior M2."),
                    F(@"ios_liquid_glass_text_layout_m2_enabled",  @"M2 Text Layout", @"Layout de texto M2."),
                    F(@"ios_liquid_glass_m_2_action_tile",         @"M2 Action Tile", @"Tile de ação M2."),
                    F(@"ios_liquid_glass_enable_new_chatbar_ux",   @"New Chatbar UX", @"Composer renovado."),
                    F(@"ios_liquid_glass_larger_composer",         @"Larger Composer", @"Composer expandido."),
                    F(@"ios_liquid_glass_unify_ui_refresh_enabled",@"Unify UI Refresh", @""),
                    F(@"ios_liquid_glass_unify_navigation_bar_enabled", @"Unify Navigation Bar", @""),
                    F(@"ios_liquid_glass_native_sidebar_enabled",  @"Native Sidebar", @""),
                    F(@"ios_liquid_glass_media_editor_enabled",    @"Media Editor", @""),
                    F(@"ios_liquid_glass_calling_improvement_enabled", @"Calling Improvement", @""),
                    F(@"ios_liquid_glass_workaround_attachment_tray",  @"Workaround Attachment Tray", @""),
                    FInv(@"ios_liquid_glass_workaround_hides_bottombar", @"Workaround Hide Bottombar (inverted)",
                       @"Quando ON, oculta a barra inferior — invertido."),
                    F(@"ios_liquid_glass_workaround_topbar_appearance", @"Workaround Top Bar Appearance", @""),
                    F(@"ios_liquid_glass_reduce_transparency",          @"Reduce Transparency", @"")
                ]),

            // ── Aura / WA Plus ───────────────────────────────────────────────
            WAGRMakeProvider(@"aura",
                @"Aura / WA Plus",
                @"Themes, App Icons, Ringtones, Subscription benefits",
                @"star",
                @[
                    @"WAAuraGating",
                    @"WAAuraGating.AuraGating",
                    @"_TtC12WAAuraGating20GatedBenefitProvider",
                    @"_TtC12WAAuraGating25GatedSubscriptionProvider",
                    @"_TtC12WAAuraGating28AuraBenefitReliabilityLogger",
                    @"_TtC12WAAuraGating28SubscriptionUserActionLogger"
                ],
                @[ @"WAAuraGating", @"AuraGating", @"AuraBenefit",
                   @"AuraSubscription", @"GatedBenefit", @"GatedSubscription",
                   @"WAAuraFoundation", @"Aura" ],
                @[ @"aura", @"subscription", @"benefit", @"theme", @"icon",
                   @"ringtone", @"sticker", @"premium" ],
                @[
                    F(@"aura_enabled",                         @"Master aura_enabled", @""),
                    F(@"aura_settings_row_enabled",            @"Settings Row",        @""),
                    F(@"new_appearance_setting_cell_enabled",  @"New Appearance Cell", @""),
                    F(@"aura_app_icon_enabled",                @"App Icons",            @""),
                    F(@"aura_app_themes_enabled",              @"App Themes",           @""),
                    F(@"aura_app_themes_chat_checkmark_themed_enabled", @"Themed Chat Checkmark", @""),
                    F(@"aura_app_themes_status_ring_enabled",  @"Status Ring Themed",   @""),
                    F(@"aura_app_themes_share_extension_themed_enabled", @"Themed Share Extension", @""),
                    F(@"aura_ringtones_enabled",               @"Ringtones",            @""),
                    F(@"aura_ringtones_per_chat_enabled",      @"Ringtones per Chat",   @""),
                    F(@"aura_stickers_enabled",                @"Stickers",             @""),
                    F(@"aura_enhanced_lists_enabled",          @"Enhanced Lists",       @""),
                    F(@"aura_pinned_chats_enabled",            @"Pinned Chats",         @""),
                    F(@"aura_subscription_simulation_enabled", @"Subscription Simulation", @""),
                    F(@"aura_logging_enabled",                 @"Aura Logging",         @""),
                    F(@"aura_app_icon_benefit_active",         @"App Icon Benefit Active", @""),
                    F(@"aura_app_icon_multi_account_support",  @"App Icon Multi-Account", @""),
                    F(@"aura_app_themes_benefit_active",       @"Theme Benefit Active", @""),
                    F(@"aura_app_themes_new_selection_flow_enabled", @"Theme New Selection Flow", @""),
                    F(@"aura_app_themes_illustration_lottie_enabled", @"Theme Illustration Lottie", @""),
                    F(@"aura_apple_watch_app_theme_enabled",   @"Apple Watch Theme", @""),
                    F(@"aura_apple_watch_app_themes_enabled",  @"Apple Watch Themes", @""),
                    F(@"aura_pinned_chats_benefit_active",     @"Pinned Chats Benefit", @""),
                    F(@"aura_pinned_chats_targeted_nux_force", @"Pinned Chats NUX Force", @""),
                    F(@"aura_enhanced_lists_benefit_active",   @"Enhanced Lists Benefit", @""),
                    F(@"aura_ringtones_benefit_active",        @"Ringtones Benefit", @""),
                    F(@"aura_stickers_benefit_active",         @"Stickers Benefit", @""),
                    F(@"aura_stickers_overlay_animation_enabled", @"Sticker Overlay Animation", @""),
                    F(@"aura_painted_door_stickers_enabled",   @"Painted Door Stickers", @""),
                    F(@"ai_subscription_enabled",              @"AI Subscription", @""),
                    F(@"ai_subscription_imagine_intent_enabled", @"AI Imagine Intent", @""),
                    F(@"wa_subscriptions_entry_point_settings_enabled", @"Subscriptions Settings Entry", @""),
                    F(@"wa_subscriptions_settings_green_dot_enabled", @"Subscriptions Green Dot", @""),
                    F(@"premium_blue_enabled",                 @"Premium Blue", @""),
                    F(@"isEnabled",                            @"AuraGating isEnabled", @""),
                    F(@"isUserEligible",                       @"User Eligible",        @""),
                    F(@"isSettingsRowEnabled",                 @"Settings Row Enabled (runtime)", @""),
                    F(@"isAppThemesEnabled",                   @"App Themes (runtime)", @""),
                    F(@"isAppIconsEnabled",                    @"App Icons (runtime)",  @""),
                    F(@"isRingtonesEnabled",                   @"Ringtones (runtime)",  @""),
                    F(@"isStickersEnabled",                    @"Stickers (runtime)",   @""),
                    FInv(@"isKillSwitchActive",                @"Kill Switch (inverted)",
                       @"ON na UI → kill switch desativado; o gate retorna NO.")
                ]),

            // ── MobileConfig ─────────────────────────────────────────────────
            WAGRMakeProvider(@"mobileconfig",
                @"MobileConfig / Gating",
                @"Fetch/cache/GraphQL/gating bridge behind WAAB",
                @"network",
                @[ @"MobileConfigGating",
                   @"_TtC12WAFoundation20WAMobileConfigGating" ],
                @[ @"WAMobileConfig", @"MobileConfig", @"WAMCShadow", @"MobileConfigGating" ],
                @[ @"sessionbased", @"mc", @"mobile_config", @"stableid", @"shadow" ],
                @[
                    F(@"isSessionBasedMCEnabled", @"Session-Based MC Enabled",     @""),
                    F(@"isSessionBasedEnabled",   @"Session-Based Enabled",        @""),
                    F(@"isSourceOfTruth",         @"Source of Truth",              @""),
                    F(@"emergencyRollback",       @"Emergency Rollback",           @""),
                    F(@"mcUseCallsiteDefault",    @"Use Callsite Default",         @""),
                    F(@"isStableIDFastParseEnabled",   @"Stable ID Fast Parse",    @""),
                    F(@"isStableIDLocalCacheEnabled",  @"Stable ID Local Cache",   @""),
                    F(@"waios_enable_sessionbased_mc", @"Enable Session-Based MC", @""),
                    F(@"waios_lazyinit_sessionbased_mc", @"Lazy Init Session-Based MC", @""),
                    F(@"ios_enable_mc_shadow_testing", @"MC Shadow Testing",       @""),
                    F(@"ios_offline_sessionless_mc_enabled", @"Offline Sessionless MC", @""),
                    F(@"ios_online_sessionless_mc_enabled",  @"Online Sessionless MC", @"")
                ]),

            // ── WAContext / WAContextMain ────────────────────────────────────
            // The provider graph. Featured rows cover internal flags that
            // mirror WAServerProperties (the bridge often exposes the same
            // boolean both ways), but most of the value here comes from the
            // runtime browser exploring the graph.
            WAGRMakeProvider(@"context",
                @"WAContext / WAContextMain",
                @"Provider graph: featureControl, auraGating, mcGating, aiGating, vault, waffle",
                @"point.3.connected.trianglepath.dotted",
                @[ @"WAContext", @"WAContextMain" ],
                @[ @"WAContext", @"ContextMain", @"WAContextDependency" ],
                @[],
                @[
                    F(@"isInternalUser",          @"isInternalUser",       @"Bridge para WAServerProperties."),
                    F(@"isEvolveAboutM1Enabled",  @"Evolve About M1",      @""),
                    F(@"isMeTabEnabled",          @"Me Tab",               @""),
                    F(@"isContactsHubEnabled",    @"Contacts Hub",         @""),
                    F(@"isUsernameExperienceEnabled", @"Username Experience", @"")
                ]),



            // ── About / Evolve ───────────────────────────────────────────────
            WAGRMakeProvider(@"about",
                @"About / Evolve",
                @"About profile/status surfaces and Evolve About M1 gates",
                @"person.text.rectangle.fill",
                @[ @"WAContext", @"WAContextMain", @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"WAContext", @"ContextMain", @"WAABProperties", @"ABProperties", @"About", @"Evolve" ],
                @[ @"about", @"evolve", @"evolution" ],
                @[
                    F(@"evolve_about_m1_enabled",                    @"Evolve About M1", @"Bundle usado pelo painel Me-Tab/Contacts."),
                    F(@"evolve_about_m1_receiver_enabled",           @"Evolve About Receiver", @"Confirmado no catálogo WAAB."),
                    F(@"evolve_about_m1_receiver_for_new_surfaces_enabled", @"Evolve About New Surfaces", @""),
                    F(@"privacy_settings_about_lid_migration_enable", @"About LID Migration", @""),
                    F(@"isEvolveAboutM1Enabled",                     @"Runtime isEvolveAboutM1Enabled", @"Getter em WAContext/WAAB."),
                    F(@"is_about_entrypoint_set",                    @"About Entrypoint", @"Logging/entrypoint guard."),
                    F(@"is_about_consumption_surface_set",           @"About Consumption Surface", @"")
                ]),

            // ── Tab Me / Profile ─────────────────────────────────────────────
            WAGRMakeProvider(@"tab_me",
                @"Tab Me / Profile",
                @"Me tab, profile picture entrypoint, account switcher and tab-bar profile state",
                @"person.crop.square.fill.and.at.rectangle",
                @[ @"WAContext", @"WAContextMain", @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"WAContext", @"ContextMain", @"WAABProperties", @"ABProperties", @"MeTab", @"AccountSwitcher", @"TabBar", @"Profile" ],
                @[ @"me_tab", @"tab_me", @"profile_picture", @"account_switcher", @"switcher", @"profile", @"tab" ],
                @[
                    F(@"me_tab_status_creation_enabled",             @"Me Tab Status Creation", @""),
                    F(@"me_tab_self_status_viewing_enabled",         @"Me Tab Self Status", @""),
                    F(@"me_tab_settings_header_enabled",             @"Me Tab Settings Header", @""),
                    F(@"me_tab_settings_title_enabled",              @"Me Tab Settings Title", @""),
                    F(@"me_tab_profile_picture_entrypoint_enabled",  @"Profile Picture Entrypoint", @""),
                    F(@"me_tab_profile_picture_abprop_sync_enabled", @"Profile Picture ABProp Sync", @""),
                    F(@"wa_account_switcher_settings_me_tab",        @"Account Switcher Settings Me Tab", @""),
                    F(@"xfam_lg_switcher_m2_me_tab_enabled",         @"XFAM LG Switcher M2 Me Tab", @""),
                    F(@"ios_me_tab_new_user_checklist_enabled",      @"New User Checklist", @""),
                    F(@"ios_me_tab_share_updates_enabled",           @"Share Updates", @""),
                    F(@"ios_me_tab_username_findability_enabled",    @"Username Findability", @""),
                    F(@"isMeTabEnabled",                             @"Runtime isMeTabEnabled", @""),
                    F(@"isMeTabProfilePictureEntrypointEnabled",     @"Runtime Profile Picture Entrypoint", @"")
                ]),

            // ── Evolution UI ─────────────────────────────────────────────────
            WAGRMakeProvider(@"evolution",
                @"Evolution UI",
                @"Modern navigation, Bloks color parameters and Evolution surface flags",
                @"sparkles.rectangle.stack.fill",
                @[ @"WAContext", @"WAContextMain", @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"Evolution", @"WAContext", @"ContextMain", @"WAABProperties", @"ABProperties" ],
                @[ @"evolution", @"evolve", @"modern", @"navigation_bar", @"bloks_color" ],
                @[
                    F(@"ios_evolution_bloks_color_theme_parameter_enabled", @"Bloks Color Theme Parameter", @""),
                    F(@"ios_evolution_navigation_bar_buttons_use_modern_style", @"Modern Nav Buttons", @""),
                    F(@"evolve_about_m1_receiver_enabled", @"Evolve About Receiver", @""),
                    F(@"isEvolveAboutM1Enabled", @"Runtime Evolve About", @"")
                ]),

            // ── Username / Identity ──────────────────────────────────────────
            WAGRMakeProvider(@"username",
                @"Username / Identity",
                @"Username creation, search, privacy, companion sync and migration gates",
                @"at.circle.fill",
                @[ @"WAContext", @"WAContextMain", @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"Username", @"WAContext", @"ContextMain", @"WAABProperties", @"ABProperties", @"Privacy" ],
                @[ @"username", @"pn_privacy", @"lid", @"findability", @"companion" ],
                @[
                    F(@"username_dogfooding_pn_privacy_enabled",       @"Dogfood PN Privacy", @""),
                    F(@"username_dogfooding_pn_privacy_periodic_conversion_enabled", @"PN Privacy Periodic Conversion", @""),
                    F(@"privacy_settings_username_sending_enable",     @"Privacy Username Sending", @""),
                    F(@"username_account_linking_enabled",             @"Account Linking", @""),
                    F(@"username_enabled_on_companion",                @"Enabled on Companion", @""),
                    F(@"username_global_search_enabled",               @"Global Search", @""),
                    F(@"username_suggestions_enabled",                 @"Suggestions", @""),
                    F(@"username_key_redesign_enabled",                @"Key Redesign", @""),
                    F(@"username_future_proof_contact_creation_enabled", @"Future Proof Contact Creation", @""),
                    F(@"username_contact_syncd_support_enable",        @"Contact Syncd Support", @""),
                    F(@"username_contact_syncd_companion_creation_support_enable", @"Companion Creation Support", @""),
                    F(@"username_contact_allow_lid_contact_storage_with_usync", @"LID Contact Storage With USync", @""),
                    F(@"ios_wabi_enable_username_migration",           @"WABI Username Migration", @""),
                    F(@"enable_calling_username",                      @"Calling Username", @""),
                    F(@"username_call_search_enabled",                 @"Call Search", @""),
                    F(@"username_group_learning_enabled",              @"Group Learning", @""),
                    F(@"username_group_mutation_enabled",              @"Group Mutation", @""),
                    F(@"isUsernameExperienceEnabled",                  @"Runtime Username Experience", @""),
                    F(@"shouldShowUsernameRowOnCompanion",             @"Runtime Companion Row", @""),
                    FInv(@"username_activation_disabled",              @"Activation Disabled (negative)", @"Ignorado pelo Aplicar em massa.")
                ]),

            // ── Online Contacts / Presence ───────────────────────────────────
            WAGRMakeProvider(@"online_contacts",
                @"Online Contacts / Presence",
                @"Contacts Hub, recently-online contacts and presence/status contact surfaces",
                @"person.2.wave.2.fill",
                @[ @"WAContext", @"WAContextMain", @"WAABProperties", @"FOAWAABPropertiesImpl" ],
                @[ @"Contacts", @"Contact", @"Presence", @"WAContext", @"ContextMain", @"WAABProperties", @"ABProperties" ],
                @[ @"contacts", @"contact", @"online", @"presence", @"recently_online", @"contactshub" ],
                @[
                    F(@"ios_contacts_surface_is_enabled",              @"Contacts Surface", @""),
                    F(@"ios_contactshub_presence_status",              @"ContactsHub Presence Status", @""),
                    F(@"shouldShowRecentlyOnlineSuggestedContacts",    @"Recently Online Suggestions", @""),
                    F(@"recently_online_contacts_enabled",             @"Recently Online Contacts", @""),
                    F(@"contacts_hub_enabled",                         @"Contacts Hub", @""),
                    F(@"contacts_hub_recently_online_enabled",         @"Contacts Hub Recently Online", @""),
                    F(@"isContactsSurfaceEnabled",                     @"Runtime Contacts Surface", @""),
                    F(@"isContactsHubEnabled",                         @"Runtime Contacts Hub", @""),
                    F(@"isRecentlyOnlineContactsEnabled",              @"Runtime Recently Online", @""),
                    F(@"allow_lid_contacts_new_1on1_chat",             @"LID Contacts New 1:1 Chat", @""),
                    F(@"allow_lid_contacts_calling",                   @"LID Contacts Calling", @""),
                    F(@"allow_lid_contacts_status",                    @"LID Contacts Status", @""),
                    F(@"non_contact_status_receiver_enabled",          @"Non-contact Status Receiver", @""),
                    F(@"out_contact_sync_primary_enabled",             @"Primary Contact Sync", @""),
                    F(@"status_audience_selection_frequent_contacts_enabled", @"Frequent Contacts Audience", @"")
                ]),

            // ── FOA / Meta Apps ──────────────────────────────────────────────
            WAGRMakeProvider(@"foa",
                @"FOA / Meta Apps",
                @"Family-of-apps utilities (Facebook, Instagram, Threads, Meta AI)",
                @"apps.iphone",
                @[ @"WAFoaAppUtilities", @"FOAWAABPropertiesImpl" ],
                @[ @"FOA", @"WAFoa", @"CrossFamily", @"MetaAI", @"Instagram", @"Threads", @"Facebook" ],
                @[ @"foa", @"facebook", @"instagram", @"threads", @"metaai", @"installed", @"bookmark", @"bridge" ],
                @[
                    F(@"foa_bookmarks_enabled",            @"FOA Bookmarks",         @""),
                    F(@"foa_threads_bookmarks_enabled",    @"Threads Bookmarks",     @""),
                    F(@"foa_bridges_account_switcher_ios_enabled", @"Account Switcher", @""),
                    F(@"wa_bookmarks_hs_fb_cta",           @"Bookmarks FB CTA",      @""),
                    F(@"wa_bookmarks_hs_ig_cta",           @"Bookmarks IG CTA",      @""),
                    F(@"wa_bookmarks_hs_meta_ai_cta",      @"Bookmarks Meta AI CTA", @""),
                    F(@"wa_bookmarks_hs_threads_cta",      @"Bookmarks Threads CTA", @"")
                ]),

            // ── WABiz / Business ─────────────────────────────────────────────
            WAGRMakeProvider(@"biz",
                @"WABiz / Business",
                @"BizManager, BizProfile, SMB, catalog/commerce surfaces",
                @"briefcase",
                @[ @"WABizProfileServerConfigs", @"WABizSearchServerConfigs", @"WABizProfileSettings" ],
                @[ @"WABiz", @"BizManager", @"BizProfile", @"BizRole", @"Business", @"SMB", @"Catalog", @"Commerce", @"Merchant" ],
                @[ @"biz", @"business", @"smb", @"merchant", @"commerce", @"catalog" ],
                @[]),

            // ── Settings & Developer ─────────────────────────────────────────
            // Read-mostly surface: featured rows are the user-visible row
            // forcers; the runtime browser exposes internal Settings VC
            // gating selectors.
            WAGRMakeProvider(@"settings",
                @"Settings / Developer",
                @"Hidden Settings rows and developer/dogfood gates",
                @"slider.horizontal.3",
                @[ @"WASettingsViewController", @"WASettingsNavigationController",
                   @"WANewSettingsViewController", @"WASettingsTableViewController",
                   @"WAEmployeeGating", @"WADebugMenuMain" ],
                @[ @"WASettings", @"WANewSettings", @"WADebugMenu", @"WADeveloper",
                   @"Employee", @"Dogfood", @"Internal" ],
                @[ @"settings", @"row", @"developer", @"debug", @"internal", @"dogfood" ],
                @[
                    F(@"wagr.settingsrows.force_subscriptions", @"Forçar linha Subscriptions",
                      @"Pref WATweaks que liga a linha Subscriptions no Settings."),
                    F(@"wagr.settingsrows.force_payments",      @"Forçar linha Payments",
                      @"Pref WATweaks que liga a linha Payments no Settings."),
                    F(@"isDebugMenuAllowed",                    @"Debug Menu Allowed",
                      @"Provider de Debug Menu (WADebugMenuMain)."),
                    F(@"isDebugMenuShortcutEnabled",            @"Debug Menu Shortcut",
                      @"Atalho para o Debug Menu nativo.")
                ])
        ];
    });
    return providers;
}

+ (WAGRGateProvider *)providerWithID:(NSString *)providerID {
    if (!providerID.length) return nil;
    for (WAGRGateProvider *p in [self allProviders]) {
        if ([p.providerID isEqualToString:providerID]) return p;
    }
    return nil;
}

@end
