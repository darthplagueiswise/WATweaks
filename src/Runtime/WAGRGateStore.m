// WAGRGateStore.m — schema v3 single-key store with lazy in-memory hot-path cache.
//
// Runtime rule:
// - Do not read NSUserDefaults on every gate check. WhatsApp calls AB/gate
//   getters thousands of times during launch, so WAGRGateIsSet/Get must be
//   dictionary-only after one lazy cache load.
// - Mutations still write NSUserDefaults + index so toggles persist.

#import "WAGRGateStore.h"

NSString * const kWAGRStorageWipedMarkerV2 = @"watweak.storage.wiped.v3";
NSString * const kWATGateOverrideIndexKey = @"watweak_gate_override_index";

static NSMutableDictionary<NSString *, NSNumber *> *gWATGateCache = nil;
static BOOL gWATGateCacheLoaded = NO;
static NSObject *gWATGateCacheLock = nil;

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
    if ([key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"watweak_ui_"]) return key;
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

static void WATEnsureGateCacheLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWATGateCacheLock = [NSObject new];
        gWATGateCache = [NSMutableDictionary dictionary];
    });

    if (gWATGateCacheLoaded) return;
    @synchronized (gWATGateCacheLock) {
        if (gWATGateCacheLoaded) return;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        for (NSString *ck in WATIndex(ud)) {
            id obj = [ud objectForKey:ck];
            if ([obj isKindOfClass:NSNumber.class]) gWATGateCache[ck] = obj;
        }
        gWATGateCacheLoaded = YES;
    }
}

static void WATGateCacheSet(NSString *ck, NSNumber *value) {
    WATEnsureGateCacheLoaded();
    @synchronized (gWATGateCacheLock) {
        if (value) gWATGateCache[ck] = value;
        else [gWATGateCache removeObjectForKey:ck];
    }
}

static NSArray<NSString *> *WAGRLegacyKeyPrefixes(void) {
    return @[ @"wagr.waab.", @"wagr.override|", @"wagr.override.", @"wagr.observed|", @"wagr.observed." ];
}

static BOOL WAGRGateStoreShouldRemoveOverrideKey(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return NO;
    if ([key isEqualToString:kWATGateOverrideIndexKey]) return YES;
    if ([key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"watweak_ui_"]) return YES;
    if ([key hasPrefix:@"wagr.dogfood.gate."] || [key hasPrefix:@"wa_lg_ios_liquid_glass_"]) return YES;
    if ([key isEqualToString:@"wagr_native_debug_menu_enabled"] || [key isEqualToString:@"wagr_internal_master_enabled"]) return YES;
    for (NSString *prefix in WAGRLegacyKeyPrefixes()) {
        if ([key hasPrefix:prefix]) return YES;
    }
    return NO;
}

BOOL WAGRGateIsSet(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return NO;
    WATEnsureGateCacheLoaded();
    return gWATGateCache[ck] != nil;
}

BOOL WAGRGateGet(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return NO;
    WATEnsureGateCacheLoaded();
    NSNumber *n = gWATGateCache[ck];
    return n ? n.boolValue : NO;
}

void WAGRGateSet(NSString *key, BOOL value) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:value forKey:ck];
    WATIndexAdd(ud, ck);
    WATGateCacheSet(ck, @(value));
    [ud synchronize];
}

void WAGRGateClear(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!ck.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:ck];
    WATIndexRemove(ud, ck);
    WATGateCacheSet(ck, nil);
    [ud synchronize];
}

NSArray<NSString *> *WAGRGateAllOverrides(void) {
    WATEnsureGateCacheLoaded();
    return [gWATGateCache.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

NSUInteger WAGRGateClearAll(void) {
    WATEnsureGateCacheLoaded();
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableSet<NSString *> *keys = [NSMutableSet setWithArray:WAGRGateAllOverrides() ?: @[]];
    for (NSString *key in ud.dictionaryRepresentation.allKeys) {
        if (WAGRGateStoreShouldRemoveOverrideKey(key)) [keys addObject:key];
    }

    NSUInteger removed = 0;
    for (NSString *key in keys) {
        if (![key isEqualToString:kWATGateOverrideIndexKey] && [ud objectForKey:key] != nil) removed++;
        [ud removeObjectForKey:key];
    }
    [ud removeObjectForKey:kWATGateOverrideIndexKey];
    @synchronized (gWATGateCacheLock) { [gWATGateCache removeAllObjects]; }
    [ud synchronize];
    return removed;
}

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
            WATGateCacheSet(canonical, @([obj boolValue]));
            [ud removeObjectForKey:key];
            migrated++;
            continue;
        }
        for (NSString *prefix in prefixes) {
            if ([key hasPrefix:prefix]) { [ud removeObjectForKey:key]; removed++; break; }
        }
    }
    [ud setBool:YES forKey:kWAGRStorageWipedMarkerV2];
    [ud synchronize];
    NSLog(@"[WATweaks][Store] legacy wipe removed %lu keys, migrated %lu aliases (schema v3 marker set)",
          (unsigned long)removed, (unsigned long)migrated);
}

NSString *WAGRGateStoreDiagnostic(void) {
    return [NSString stringWithFormat:
        @"schema=v3 cached\nactive overrides=%lu\nlegacy wipe=%@",
        (unsigned long)WAGRGateAllOverrides().count,
        [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRStorageWipedMarkerV2] ? @"done" : @"pending"];
}
