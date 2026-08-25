// WAAuraHooks.xm — Aura / WA Plus semantic gating
//
// Current-build validation (SharedModules(4), arm64, 2026-08-25):
// WAAuraGating does NOT expose the snake_case WAAB selectors as its semantic API.
// Those names live on the ABProps/WAAB layer.  WAAuraGating exposes isXxx methods.
//
// Confirmed semantic selectors in the supplied framework include:
//   isEnabled, isUserEligible, isSettingsRowEnabled, isKillSwitchActive,
//   isAppearanceSettingsEnabled, isAppIconsEnabled, isAppIconsBenefitActive,
//   isAppIconMultiAccountSupportEnabled, isAppThemesEnabled,
//   isAppThemesBenefitActive, isAppThemesLottieEnabled,
//   isAppThemeNewChatPreviewFlowEnabled, isAppThemesStatusRingEnabled,
//   isAppThemesChatCheckmarkThemedEnabled, isRingtonesEnabled,
//   isRingtonesBenefitActive, isRingtonesPerChatEnabled,
//   isExtendedPinnedChatEnabled, isExtendedPinnedChatBenefitActive,
//   isEnhancedListsEnabled, isEnhancedListsBenefitActive, isStickersEnabled,
//   isStickersBenefitActive, isVaultBackupsEnabled, isVaultBackupsBenefitActive,
//   isCustomReactionsEnabled, isCustomReactionsBenefitActive,
//   isExclusiveStickersInFreePacksEnabled and isUserEligibleFor:.
//
// The corresponding snake_case selectors are ABProp inputs such as aura_enabled,
// aura_app_themes_enabled, aura_ringtones_enabled, etc.  This file bridges the
// two layers instead of trying to hook snake_case selectors on WAAuraGating.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

#include <stdint.h>
#include <string.h>

static NSMutableDictionary<NSString *, NSValue *> *gAuraOrig = nil;
static NSMutableSet<NSString *> *gAuraHookedSelectors = nil;
static BOOL gAuraInstalled = NO;

typedef BOOL (*WAAuraBoolIMP)(id, SEL);
typedef BOOL (*WAAuraWordBoolIMP)(id, SEL, uintptr_t);

#pragma mark - Current-build semantic -> ABProp mapping

static NSDictionary<NSString *, NSString *> *WAGRAuraSemanticABMap(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"isEnabled" : @"aura_enabled",
            @"isLoggingEnabled" : @"aura_logging_enabled",
            @"isSettingsRowEnabled" : @"aura_settings_row_enabled",

            @"isAppIconsEnabled" : @"aura_app_icon_enabled",
            @"isAppIconsBenefitActive" : @"aura_app_icon_benefit_active",
            @"isAppIconMultiAccountSupportEnabled" : @"aura_app_icon_multi_account_support",

            @"isAppThemesEnabled" : @"aura_app_themes_enabled",
            @"isAppThemesBenefitActive" : @"aura_app_themes_benefit_active",
            @"isAppThemesLottieEnabled" : @"aura_app_themes_illustration_lottie_enabled",
            @"isAppThemeNewChatPreviewFlowEnabled" : @"aura_app_themes_new_selection_flow_enabled",
            @"isAppThemesStatusRingEnabled" : @"aura_app_themes_status_ring_enabled",
            @"isAppThemesChatCheckmarkThemedEnabled" : @"aura_app_themes_chat_checkmark_themed_enabled",

            @"isRingtonesEnabled" : @"aura_ringtones_enabled",
            @"isRingtonesBenefitActive" : @"aura_ringtones_benefit_active",
            @"isRingtonesPerChatEnabled" : @"aura_ringtones_per_chat_enabled",

            @"isExtendedPinnedChatEnabled" : @"aura_pinned_chats_enabled",
            @"isExtendedPinnedChatBenefitActive" : @"aura_pinned_chats_benefit_active",

            @"isEnhancedListsEnabled" : @"aura_enhanced_lists_enabled",
            @"isEnhancedListsBenefitActive" : @"aura_enhanced_lists_benefit_active",

            @"isStickersEnabled" : @"aura_stickers_enabled",
            @"isStickersBenefitActive" : @"aura_stickers_benefit_active",

            @"isVaultBackupsEnabled" : @"aura_vault_backups_enabled",
            @"isVaultBackupsBenefitActive" : @"aura_vault_backups_benefit_active",

            @"isCustomReactionsEnabled" : @"aura_custom_reactions_enabled",
            @"isCustomReactionsBenefitActive" : @"aura_custom_reactions_benefit_active",

            @"isExclusiveStickersInFreePacksEnabled" : @"aura_exclusive_stickers_in_free_packs_enabled",
        };
    });
    return map;
}

static NSDictionary<NSString *, NSString *> *WAGRAuraNegativeSemanticABMap(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // These are raw negative gates.  TRUE means the kill/block condition is active.
        map = @{
            @"isKillSwitchActive" : @"aura_kill_switch",
        };
    });
    return map;
}

static NSArray<NSString *> *WAGRAuraUnmappedPositiveSelectors(void) {
    // These are semantic gates confirmed in WAAuraGating but do not have a safe
    // 1:1 snake_case parameter mapping.  The Aura master may force them, while
    // the native implementation remains authoritative otherwise.
    return @[
        @"isUserEligible",
        @"isAppearanceSettingsEnabled",
    ];
}

#pragma mark - RuntimeValueStore / GateStore bridge

static BOOL WAGRAuraRuntimeBoolOverrideForABSelector(NSString *selectorName,
                                                      BOOL *outValue) {
    if (!selectorName.length) return NO;

    NSDictionary *stored = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kWAGRRuntimeValueOverridesKey];
    if (![stored isKindOfClass:NSDictionary.class] || stored.count == 0) return NO;

    NSDictionary *fallback = nil;
    for (id rawSpec in stored.allValues) {
        if (![rawSpec isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *spec = (NSDictionary *)rawSpec;
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class]
            ? spec[@"selector"] : nil;
        if (![selector isEqualToString:selectorName]) continue;

        NSString *type = [spec[@"type"] isKindOfClass:NSString.class]
            ? spec[@"type"] : @"";
        if (![type isEqualToString:@"B"] && ![type isEqualToString:@"c"]) continue;
        id value = spec[@"value"];
        if (![value respondsToSelector:@selector(boolValue)]) continue;

        NSString *className = [spec[@"class"] isKindOfClass:NSString.class]
            ? spec[@"class"] : @"";
        // The semantic WAAuraGating path consumes WAABProperties. Prefer an
        // override attached to that class when duplicate selector names exist.
        if ([className isEqualToString:@"WAABProperties"]) {
            if (outValue) *outValue = [value boolValue];
            return YES;
        }
        if (!fallback) fallback = spec;
    }

    if (fallback) {
        if (outValue) *outValue = [fallback[@"value"] boolValue];
        return YES;
    }
    return NO;
}

static BOOL WAGRAuraRawOverrideForABSelector(NSString *selectorName,
                                              BOOL *outValue) {
    BOOL value = NO;
    if (WAGRAuraRuntimeBoolOverrideForABSelector(selectorName, &value)) {
        if (outValue) *outValue = value;
        return YES;
    }
    if (selectorName.length && WAGRGateIsSet(selectorName)) {
        if (outValue) *outValue = WAGRGateGet(selectorName);
        return YES;
    }
    return NO;
}

static BOOL WAGRAuraActive(void) {
    if (WAGRPref(kWAGRAuraSimulation)) return YES;

    BOOL value = NO;
    if (WAGRAuraRawOverrideForABSelector(@"aura_enabled", &value) && value) return YES;
    if (WAGRAuraRawOverrideForABSelector(@"aura_subscription_simulation_enabled", &value) && value) return YES;
    return NO;
}

static BOOL WAGRAuraHasAnyPersistedOverride(void) {
    if (WAGRPref(kWAGRAuraSimulation)) return YES;

    NSDictionary *stored = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kWAGRRuntimeValueOverridesKey];
    for (id rawSpec in stored.allValues) {
        if (![rawSpec isKindOfClass:NSDictionary.class]) continue;
        NSString *selector = [rawSpec[@"selector"] isKindOfClass:NSString.class]
            ? rawSpec[@"selector"] : nil;
        if ([selector hasPrefix:@"aura_"]) return YES;
    }

    for (NSString *selector in WAGRAuraSemanticABMap().allValues) {
        if (WAGRGateIsSet(selector)) return YES;
    }
    for (NSString *selector in WAGRAuraNegativeSemanticABMap().allValues) {
        if (WAGRGateIsSet(selector)) return YES;
    }
    return WAGRGateIsSet(@"aura_subscription_simulation_enabled");
}

#pragma mark - ABI validation

static const char *WAGRAuraSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRAuraMethodReturnsBool(Method method) {
    if (!method) return NO;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    char type = WAGRAuraSkipQualifiers(raw)[0];
    return type == 'B' || type == 'c';
}

static BOOL WAGRAuraMethodHasWordArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRAuraSkipQualifiers(raw);
    if (!*type || type[0] == 'f' || type[0] == 'd' || type[0] == '{' || type[0] == '(' || type[0] == '[') {
        return NO;
    }
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uintptr_t);
}

#pragma mark - Hook implementations

static NSString *WAGRAuraOrigKey(id self, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass([self class]) ?: @"WAAuraGating",
            NSStringFromSelector(selector) ?: @"?"];
}

static BOOL WAGRAuraOriginalBool(id self, SEL selector, BOOL fallback) {
    NSValue *value = gAuraOrig[WAGRAuraOrigKey(self, selector)];
    WAAuraBoolIMP original = value
        ? reinterpret_cast<WAAuraBoolIMP>([value pointerValue]) : NULL;
    return original ? original(self, selector) : fallback;
}

static BOOL WAGRAuraHookPositive(id self, SEL _cmd) {
    NSString *semantic = NSStringFromSelector(_cmd) ?: @"";
    NSString *abSelector = WAGRAuraSemanticABMap()[semantic];

    BOOL raw = NO;
    if (abSelector.length && WAGRAuraRawOverrideForABSelector(abSelector, &raw)) {
        return raw;
    }
    if (WAGRAuraActive()) return YES;
    return WAGRAuraOriginalBool(self, _cmd, NO);
}

static BOOL WAGRAuraHookNegative(id self, SEL _cmd) {
    NSString *semantic = NSStringFromSelector(_cmd) ?: @"";
    NSString *abSelector = WAGRAuraNegativeSemanticABMap()[semantic];

    BOOL raw = NO;
    if (abSelector.length && WAGRAuraRawOverrideForABSelector(abSelector, &raw)) {
        return raw;
    }
    if (WAGRAuraActive()) return NO;
    return WAGRAuraOriginalBool(self, _cmd, YES);
}

static BOOL WAGRAuraHookUnmappedPositive(id self, SEL _cmd) {
    if (WAGRAuraActive()) return YES;
    return WAGRAuraOriginalBool(self, _cmd, NO);
}

static BOOL WAGRAuraHookUserEligibleFor(id self, SEL _cmd, uintptr_t benefit) {
    NSString *key = WAGRAuraOrigKey(self, _cmd);
    NSValue *value = gAuraOrig[key];
    WAAuraWordBoolIMP original = value
        ? reinterpret_cast<WAAuraWordBoolIMP>([value pointerValue]) : NULL;
    if (WAGRAuraActive()) return YES;
    return original ? original(self, _cmd, benefit) : NO;
}

static BOOL WAGRAuraInstallZeroArgHook(Class cls,
                                       NSString *selectorName,
                                       IMP replacement) {
    if (!cls || !selectorName.length || !replacement) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRAuraMethodReturnsBool(method)) return NO;

    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     NSStringFromClass(cls) ?: @"WAAuraGating", selectorName];
    if (gAuraOrig[key]) return YES;

    IMP original = NULL;
    MSHookMessageEx(cls, selector, replacement, &original);
    if (!original) return NO;
    gAuraOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(original)];
    [gAuraHookedSelectors addObject:selectorName];
    return YES;
}

static BOOL WAGRAuraInstallUserEligibleForHook(Class cls) {
    if (!cls) return NO;
    NSString *selectorName = @"isUserEligibleFor:";
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRAuraMethodReturnsBool(method) ||
        !WAGRAuraMethodHasWordArgument(method, 2)) return NO;

    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     NSStringFromClass(cls) ?: @"WAAuraGating", selectorName];
    if (gAuraOrig[key]) return YES;

    IMP original = NULL;
    MSHookMessageEx(cls, selector, (IMP)WAGRAuraHookUserEligibleFor, &original);
    if (!original) return NO;
    gAuraOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(original)];
    [gAuraHookedSelectors addObject:selectorName];
    return YES;
}

static void installAuraHooks(void) {
    if (!gAuraOrig) gAuraOrig = [NSMutableDictionary dictionary];
    if (!gAuraHookedSelectors) gAuraHookedSelectors = [NSMutableSet set];

    Class cls = NSClassFromString(@"WAAuraGating") ?: objc_getClass("WAAuraGating");
    if (!cls) {
        gAuraInstalled = NO;
        NSLog(@"[WATweaks][Aura] WAAuraGating not loaded");
        return;
    }

    [WAGRAuraSemanticABMap() enumerateKeysAndObjectsUsingBlock:
        ^(NSString *semantic, __unused NSString *abSelector, BOOL *stop) {
            (void)stop;
            WAGRAuraInstallZeroArgHook(cls, semantic, (IMP)WAGRAuraHookPositive);
        }];

    [WAGRAuraNegativeSemanticABMap() enumerateKeysAndObjectsUsingBlock:
        ^(NSString *semantic, __unused NSString *abSelector, BOOL *stop) {
            (void)stop;
            WAGRAuraInstallZeroArgHook(cls, semantic, (IMP)WAGRAuraHookNegative);
        }];

    for (NSString *semantic in WAGRAuraUnmappedPositiveSelectors()) {
        WAGRAuraInstallZeroArgHook(cls, semantic, (IMP)WAGRAuraHookUnmappedPositive);
    }

    WAGRAuraInstallUserEligibleForHook(cls);

    gAuraInstalled = gAuraOrig.count > 0;
    NSLog(@"[WATweaks][Aura] WAAuraGating semantic hooks=%lu installed=%@ selectors=%@",
          (unsigned long)gAuraOrig.count,
          gAuraInstalled ? @"YES" : @"NO",
          [[gAuraHookedSelectors allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]);
}

#pragma mark - Public bridge

extern "C" void WAGRAuraEnsureHooksInstalled(void) {
    installAuraHooks();
}

extern "C" BOOL WAGRAuraSimulationEnabled(void) {
    return WAGRAuraActive();
}

extern "C" BOOL WAGROpenSubscriptionsNative(void) {
    return NSClassFromString(@"WAAuraGating") != nil;
}

extern "C" NSString *WAGRAuraDiagnostic(void) {
    BOOL runtimeAura = NO;
    BOOL hasRuntimeAura = WAGRAuraRuntimeBoolOverrideForABSelector(@"aura_enabled", &runtimeAura);
    BOOL runtimeSubscription = NO;
    BOOL hasRuntimeSubscription = WAGRAuraRuntimeBoolOverrideForABSelector(
        @"aura_subscription_simulation_enabled", &runtimeSubscription);

    NSArray *selectors = [[gAuraHookedSelectors allObjects]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return [NSString stringWithFormat:
        @"simulation=%@\nWAAuraGating=%@\nsemanticHooks=%lu\nselectors=%@\n"
         "gateStore.aura_enabled=%@\nruntime.aura_enabled=%@%@\n"
         "runtime.aura_subscription_simulation_enabled=%@%@",
        WAGRAuraActive() ? @"ON" : @"OFF",
        NSClassFromString(@"WAAuraGating") ? @"found" : @"missing",
        (unsigned long)gAuraOrig.count,
        selectors.count ? [selectors componentsJoinedByString:@", "] : @"none",
        WAGRGateIsSet(@"aura_enabled")
            ? (WAGRGateGet(@"aura_enabled") ? @"YES" : @"NO") : @"unset",
        hasRuntimeAura ? @"set:" : @"unset",
        hasRuntimeAura ? (runtimeAura ? @"YES" : @"NO") : @"",
        hasRuntimeSubscription ? @"set:" : @"unset",
        hasRuntimeSubscription ? (runtimeSubscription ? @"YES" : @"NO") : @""];
}

__attribute__((constructor))
static void WAGRAuraCtor(void) {
    @autoreleasepool {
        // Cheap current-build semantic hook set only when Aura was already
        // requested.  No runtime/class scan is performed at cold start.
        if (WAGRAuraHasAnyPersistedOverride()) installAuraHooks();
    }
}
