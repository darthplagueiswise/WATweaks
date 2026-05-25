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
