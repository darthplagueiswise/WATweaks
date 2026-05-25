// WAGRGateStore.m — schema v2 single-key store.
// ─────────────────────────────────────────────────────────────────────────────
// Mechanics
// ─────────
// Every accessor goes through NSUserDefaults directly. We do not cache: gate
// reads happen inside MSHookMessageEx trampolines that already pay the cost
// of dispatching the call, and any cache would have to be invalidated on
// every UI toggle anyway. Keeping it direct also means the runtime browser
// always sees the live truth without an explicit refresh step.
//
// Synchronization is performed at the end of mutations only. NSUserDefaults
// already handles atomic single-key writes; -synchronize merely flushes the
// in-memory store to disk so a hard exit() right after a write does not
// lose the value (the WATweaks "Restart" action does exactly that).
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRGateStore.h"

NSString * const kWAGRStorageWipedMarkerV2 = @"watweak.storage.wiped.v3";
NSString * const kWATGateOverrideIndexKey = @"watweak_gate_override_index";

static NSString *WATNormalizeTarget(NSString *target) {
    if (!target.length) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:target.length];
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    for (NSUInteger i = 0; i < target.length; i++) {
        unichar ch = [target characterAtIndex:i];
        if ([ok characterIsMember:ch]) [out appendFormat:@"%C", ch];
        else [out appendString:@"_"];
    }
    while ([out containsString:@"__"]) [out replaceOccurrencesOfString:@"__" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    while ([out hasPrefix:@"_"]) [out deleteCharactersInRange:NSMakeRange(0, 1)];
    while ([out hasSuffix:@"_"]) [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    return out.length ? out : @"unknown";
}

NSString *WATCanonicalPreferenceKey(NSString *domain, NSString *target) {
    NSString *d = WATNormalizeTarget(domain ?: @"gate").lowercaseString;
    NSString *t = WATNormalizeTarget(target);
    if (!d.length) d = @"gate";
    return [NSString stringWithFormat:@"watweak_%@_%@", d, t];
}

static NSDictionary<NSString *, NSString *> *WAGRAliasToGateTarget(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"wagr_native_debug_menu_enabled": @"isDebugMenuAllowed",
            @"wagr_internal_master_enabled": @"isInternalUser",
            @"wagr.dogfood.gate.isMetaEmployeeOrInternalTester": @"isMetaEmployeeOrInternalTester",
            @"wagr.dogfood.gate.is_meta_employee_or_internal_tester": @"is_meta_employee_or_internal_tester",
            @"wagr.dogfood.gate.isInternalUser": @"isInternalUser",
            @"wagr.dogfood.gate.graphQLEmployeeC1Disabled": @"graphQLEmployeeC1Disabled",
            @"wa_lg_ios_liquid_glass_enabled": @"ios_liquid_glass_enabled",
            @"wa_lg_ios_liquid_glass_launched": @"ios_liquid_glass_launched",
            @"wa_lg_ios_liquid_glass_m1": @"ios_liquid_glass_m1",
            @"wa_lg_ios_liquid_glass_m_1_5": @"ios_liquid_glass_m_1_5",
            @"wa_lg_ios_liquid_glass_m_1_5_context_menu": @"ios_liquid_glass_m_1_5_context_menu",
            @"wa_lg_ios_liquid_glass_chat_top_bar_m2_enabled": @"ios_liquid_glass_chat_top_bar_m2_enabled",
            @"wa_lg_ios_liquid_glass_enable_new_chatbar_ux": @"ios_liquid_glass_enable_new_chatbar_ux",
            @"wa_lg_ios_liquid_glass_larger_composer": @"ios_liquid_glass_larger_composer",
            @"wa_lg_ios_liquid_glass_reduce_transparency": @"ios_liquid_glass_reduce_transparency",
            @"wa_lg_ios_liquid_glass_workaround_attachment_tray": @"ios_liquid_glass_workaround_attachment_tray",
            @"wa_lg_ios_liquid_glass_workaround_hides_bottombar": @"ios_liquid_glass_workaround_hides_bottombar",
            @"wa_lg_ios_liquid_glass_workaround_topbar_appearance": @"ios_liquid_glass_workaround_topbar_appearance"
        };
    });
    return map;
}

NSString *WAGRGateCanonicalKey(NSString *key) {
    if (!key.length) return @"";
    if ([key hasPrefix:@"watweak_gate_"]) return key;
    NSString *target = WAGRAliasToGateTarget()[key] ?: key;
    if ([target hasPrefix:@"wagr.settingsrows."]) return WATCanonicalPreferenceKey(@"ui", target);
    return WATCanonicalPreferenceKey(@"gate", target);
}

NSString *WAGRGateDisplayKey(NSString *key) {
    if (!key.length) return @"";
    if ([key hasPrefix:@"watweak_gate_"]) return [key substringFromIndex:[@"watweak_gate_" length]];
    if ([key hasPrefix:@"watweak_ui_"]) return [key substringFromIndex:[@"watweak_ui_" length]];
    return WAGRAliasToGateTarget()[key] ?: key;
}

static NSArray<NSString *> *WATIndex(NSUserDefaults *ud) {
    id obj = [ud objectForKey:kWATGateOverrideIndexKey];
    if (![obj isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id k in (NSArray *)obj) {
        if (![k isKindOfClass:NSString.class] || ![(NSString *)k length]) continue;
        NSString *ck = WAGRGateCanonicalKey(k);
        if (!ck.length || [seen containsObject:ck]) continue;
        [seen addObject:ck];
        [out addObject:ck];
    }
    return out;
}

static void WATWriteIndex(NSUserDefaults *ud, NSArray<NSString *> *keys) {
    [ud setObject:keys ?: @[] forKey:kWATGateOverrideIndexKey];
}

static void WATIndexAdd(NSUserDefaults *ud, NSString *canonical) {
    if (!canonical.length) return;
    NSMutableArray *idx = [WATIndex(ud) mutableCopy];
    if (![idx containsObject:canonical]) [idx addObject:canonical];
    WATWriteIndex(ud, idx);
}

static void WATIndexRemove(NSUserDefaults *ud, NSString *canonical) {
    if (!canonical.length) return;
    NSMutableArray *idx = [WATIndex(ud) mutableCopy];
    [idx removeObject:canonical];
    WATWriteIndex(ud, idx);
}

// ── Legacy prefixes we wipe on the first v2 launch ───────────────────────────
// Order: most-specific first. Anything matching ANY of these prefixes is
// removed in a single dictionaryRepresentation pass.
static NSArray<NSString *> *WAGRLegacyKeyPrefixes(void) {
    return @[
        @"wagr.waab.",       // legacy WAAB string-state store
        @"wagr.override|",   // legacy pipe-separated runtime override
        @"wagr.override.",   // even older dot-separated runtime override
        @"wagr.observed|",   // observation mirror for the pipe schema
        @"wagr.observed."    // observation mirror for the dot schema
    ];
}

// ── Accessors ────────────────────────────────────────────────────────────────
BOOL WAGRGateIsSet(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return NO;
    return [[NSUserDefaults standardUserDefaults] objectForKey:ck] != nil;
}

BOOL WAGRGateGet(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return NO;
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:ck];
    return obj ? [obj boolValue] : NO;
}

void WAGRGateSet(NSString *key, BOOL value) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:value forKey:ck];
    WATIndexAdd(ud, ck);
    [ud synchronize];
}

void WAGRGateClear(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:ck];
    WATIndexRemove(ud, ck);
    [ud synchronize];
}

NSArray<NSString *> *WAGRGateAllOverrides(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *ck in WATIndex(ud)) {
        id obj = [ud objectForKey:ck];
        if ([obj isKindOfClass:NSNumber.class]) [out addObject:ck];
    }
    return out;
}

NSUInteger WAGRGateClearAll(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *keys = WAGRGateAllOverrides();
    for (NSString *key in keys) [ud removeObjectForKey:key];
    [ud removeObjectForKey:kWATGateOverrideIndexKey];
    [ud synchronize];
    return keys.count;
}

// ── Wipe ─────────────────────────────────────────────────────────────────────
void WAGRWipeLegacyStorageIfNeeded(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kWAGRStorageWipedMarkerV2]) return;

    NSArray<NSString *> *prefixes = WAGRLegacyKeyPrefixes();
    NSDictionary *all = [ud dictionaryRepresentation];
    NSUInteger removed = 0, migrated = 0;
    for (NSString *key in all) {
        if (![key isKindOfClass:NSString.class]) continue;

        id obj = all[key];
        NSString *canonical = WAGRGateCanonicalKey(key);
        BOOL isLegacyAlias = ![canonical isEqualToString:key] &&
            ([key hasPrefix:@"wagr.dogfood.gate."] ||
             [key hasPrefix:@"wa_lg_ios_liquid_glass_"] ||
             [key isEqualToString:@"wagr_native_debug_menu_enabled"] ||
             [key isEqualToString:@"wagr_internal_master_enabled"]);
        if (isLegacyAlias && [obj isKindOfClass:NSNumber.class]) {
            [ud setBool:[obj boolValue] forKey:canonical];
            WATIndexAdd(ud, canonical);
            [ud removeObjectForKey:key];
            migrated++;
            continue;
        }

        for (NSString *prefix in prefixes) {
            if ([key hasPrefix:prefix]) {
                [ud removeObjectForKey:key];
                removed++;
                break;
            }
        }
    }
    [ud setBool:YES forKey:kWAGRStorageWipedMarkerV2];
    [ud synchronize];
    NSLog(@"[WATweaks][Store] legacy wipe removed %lu keys, migrated %lu aliases (schema v3 marker set)",
          (unsigned long)removed, (unsigned long)migrated);
}

NSString *WAGRGateStoreDiagnostic(void) {
    return [NSString stringWithFormat:
        @"schema=v3 (watweak canonical keys)\nactive overrides=%lu\nlegacy wipe=%@",
        (unsigned long)WAGRGateAllOverrides().count,
        [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRStorageWipedMarkerV2] ? @"done" : @"pending"];
}
