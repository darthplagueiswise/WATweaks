// WAAuraHooks.xm — Aura / WA Plus gating
//
// ANÁLISE BINÁRIA (SharedModules arm64, capstone+lief):
//
//   Classe confirmada: WAAuraGating (ObjC, SharedModules)
//   Módulo Swift associado: _TtC12WAAuraGating (GatedBenefitProvider, etc.)
//
//   CRÍTICO: Os seletores são snake_case, NÃO isXxx!
//   Binário confirma (methnames scan):
//     aura_enabled, aura_settings_row_enabled, aura_subscription_simulation_enabled
//     aura_app_icon_enabled, aura_app_icon_benefit_active, ...
//     aura_kill_switch (negativo — deve retornar NO para ativar)
//
//   O código anterior tentava hookear isEnabled, isUserEligible, isSettingsRowEnabled
//   que NÃO EXISTEM em WAAuraGating neste build → hooks silenciosamente falhavam.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

static NSMutableDictionary<NSString *, NSValue *> *gAuraOrig = nil;
static BOOL gAuraInstalled = NO;
typedef BOOL (*WAAuraBoolIMP)(id,SEL);

// Confirmados via __objc_methname scan de SharedModules
static NSArray<NSString *> *WAGRAuraPositiveSelectors(void) {
    return @[
        @"aura_enabled", @"aura_settings_row_enabled", @"aura_logging_enabled",
        @"aura_subscription_simulation_enabled",
        @"aura_app_icon_enabled", @"aura_app_icon_benefit_active",
        @"aura_app_icon_multi_account_support",
        @"aura_app_themes_enabled", @"aura_app_themes_benefit_active",
        @"aura_app_themes_chat_checkmark_themed_enabled",
        @"aura_app_themes_new_selection_flow_enabled",
        @"aura_app_themes_share_extension_themed_enabled",
        @"aura_app_themes_status_ring_enabled",
        @"aura_app_themes_illustration_lottie_enabled",
        @"aura_apple_watch_app_theme_enabled", @"aura_apple_watch_app_themes_enabled",
        @"aura_pinned_chats_enabled", @"aura_pinned_chats_benefit_active",
        @"aura_pinned_chats_targeted_nux_force",
        @"aura_enhanced_lists_enabled", @"aura_enhanced_lists_benefit_active",
        @"aura_ringtones_enabled", @"aura_ringtones_benefit_active",
        @"aura_ringtones_per_chat_enabled",
        @"aura_stickers_enabled", @"aura_stickers_benefit_active",
        @"aura_stickers_overlay_animation_enabled",
        @"aura_painted_door_stickers_enabled",
        @"aura_vault_backups_enabled", @"aura_vault_backups_benefit_active",
    ];
}
// Negativo: forçar NO = feature habilitada
static NSArray<NSString *> *WAGRAuraNegativeSelectors(void) {
    return @[
        @"aura_kill_switch",
        @"aura_premium_stickers_killswitch",
        @"aura_stickers_old_client_block_enabled",
    ];
}

static BOOL WAGRAuraActive(void) {
    return WAGRPref(kWAGRAuraSimulation) || WAGRIsOn(@"aura_enabled") || WAGRIsOn(@"aura_subscription_simulation_enabled");
}

static BOOL hook_aura_positive(id self, SEL _cmd) {
    NSString *sel = NSStringFromSelector(_cmd);
    NSString *k = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]), sel];
    WAAuraBoolIMP orig = gAuraOrig[k] ? reinterpret_cast<WAAuraBoolIMP>([gAuraOrig[k] pointerValue]) : NULL;
    BOOL original = orig ? orig(self, _cmd) : NO;
    // WAAB per-key override wins over master
    if (WAGRGateIsSet(sel)) return WAGRGateGet(sel);
    if (WAGRAuraActive()) return YES;
    return original;
}
static BOOL hook_aura_negative(id self, SEL _cmd) {
    NSString *sel = NSStringFromSelector(_cmd);
    NSString *k = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]), sel];
    WAAuraBoolIMP orig = gAuraOrig[k] ? reinterpret_cast<WAAuraBoolIMP>([gAuraOrig[k] pointerValue]) : NULL;
    BOOL original = orig ? orig(self, _cmd) : YES;
    if (WAGRGateIsSet(sel)) return !WAGRGateGet(sel);
    if (WAGRAuraActive()) return NO; // killswitch OFF = feature ON
    return original;
}

static void hookAuraSel(Class cls, NSString *selName, BOOL negative) {
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return;
    char ret[8]={0}; method_getReturnType(m,ret,sizeof(ret));
    if (ret[0]!='B' && ret[0]!='c') return;
    NSString *k = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), selName];
    if (gAuraOrig[k]) return;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, negative ? (IMP)hook_aura_negative : (IMP)hook_aura_positive, &orig);
    if (orig) gAuraOrig[k] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
}

static NSArray<NSString *> *WAGRAuraClasses(void) {
    return @[
        @"WAAuraGating",
        @"_TtC12WAAuraGating20GatedBenefitProvider",
        @"_TtC12WAAuraGating25GatedSubscriptionProvider",
        @"_TtC12WAAuraGating14AuraBenefitReliabilityLogger",
    ];
}

static void installAuraHooks(void) {
    if (!gAuraOrig) gAuraOrig = [NSMutableDictionary dictionary];
    for (NSString *clsName in WAGRAuraClasses()) {
        Class cls = NSClassFromString(clsName) ?: objc_getClass(clsName.UTF8String);
        if (!cls) continue;
        for (NSString *sel in WAGRAuraPositiveSelectors()) hookAuraSel(cls, sel, NO);
        for (NSString *sel in WAGRAuraNegativeSelectors()) hookAuraSel(cls, sel, YES);
    }
    gAuraInstalled = gAuraOrig.count > 0;
    NSLog(@"[WATweaks][Aura] hooks=%lu installed=%@",
          (unsigned long)gAuraOrig.count, gAuraInstalled?@"YES":@"NO");
}

extern "C" void WAGRAuraEnsureHooksInstalled(void) { installAuraHooks(); }
extern "C" BOOL WAGRAuraSimulationEnabled(void) { return WAGRAuraActive(); }
extern "C" BOOL WAGROpenSubscriptionsNative(void) {
    return NSClassFromString(@"WAAuraGating") != nil;
}
extern "C" NSString *WAGRAuraDiagnostic(void) {
    return [NSString stringWithFormat:
        @"simulation=%@\\naura_enabled_override=%@\\nWAAuraGating=%@\\nhooks=%lu",
        WAGRAuraActive()?@"ON":@"OFF",
        WAGRGateIsSet(@"aura_enabled")?@"SET":@"NOT SET",
        NSClassFromString(@"WAAuraGating")?@"found":@"missing",
        (unsigned long)gAuraOrig.count];
}

// startup is coordinated by WAGRBootstrap.xm
static void WAGRAuraCtor(void) {
    @autoreleasepool {
        installAuraHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1*NSEC_PER_SEC)),
                       dispatch_get_main_queue(),^{ installAuraHooks(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(4*NSEC_PER_SEC)),
                       dispatch_get_main_queue(),^{ installAuraHooks(); });
    }
}
