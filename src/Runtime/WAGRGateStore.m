#import "WAGRGateStore.h"

NSString * const kWAGRStorageWipedMarkerV2 = @"watweak.storage.wiped.v3";
NSString * const kWATGateOverrideIndexKey = @"watweak_gate_override_index";

static NSString *WATClean(NSString *s) {
    if (!s.length) return @"unknown";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([ok characterIsMember:c]) [out appendFormat:@"%C", c]; else [out appendString:@"_"];
    }
    while ([out containsString:@"__"]) [out replaceOccurrencesOfString:@"__" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    while ([out hasPrefix:@"_"]) [out deleteCharactersInRange:NSMakeRange(0, 1)];
    while ([out hasSuffix:@"_"]) [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    return out.length ? out : @"unknown";
}

NSString *WATCanonicalPreferenceKey(NSString *domain, NSString *target) {
    return [NSString stringWithFormat:@"watweak_%@_%@", WATClean(domain ?: @"gate").lowercaseString, WATClean(target)];
}

static NSString *WATGateTargetForKey(NSString *key) {
    if (!key.length) return @"";
    NSDictionary *map = @{
        @"wagr_native_debug_menu_enabled": @"isDebugMenuAllowed",
        @"wagr_internal_master_enabled": @"isInternalUser",
        @"wagr.dogfood.gate.isMetaEmployeeOrInternalTester": @"isMetaEmployeeOrInternalTester",
        @"wagr.dogfood.gate.is_meta_employee_or_internal_tester": @"is_meta_employee_or_internal_tester",
        @"wagr.dogfood.gate.isInternalUser": @"isInternalUser",
        @"wagr.dogfood.gate.graphQLEmployeeC1Disabled": @"graphQLEmployeeC1Disabled"
    };
    NSString *mapped = map[key];
    if (mapped.length) return mapped;
    if ([key hasPrefix:@"wa_lg_"]) return [key substringFromIndex:6];
    return key;
}

NSString *WAGRGateCanonicalKey(NSString *key) {
    if (!key.length) return @"";
    if ([key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"watweak_ui_"]) return key;
    NSString *target = WATGateTargetForKey(key);
    if ([target hasPrefix:@"wagr.settingsrows."]) return WATCanonicalPreferenceKey(@"ui", target);
    return WATCanonicalPreferenceKey(@"gate", target);
}

NSString *WAGRGateDisplayKey(NSString *key) {
    if (!key.length) return @"";
    if ([key hasPrefix:@"watweak_gate_"]) return [key substringFromIndex:[@"watweak_gate_" length]];
    if ([key hasPrefix:@"watweak_ui_"]) return [key substringFromIndex:[@"watweak_ui_" length]];
    return WATGateTargetForKey(key);
}

static BOOL WATOwned(NSString *key) {
    return [key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"watweak_ui_"];
}

static NSArray<NSString *> *WATKeys(NSUserDefaults *ud) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    id idx = [ud objectForKey:kWATGateOverrideIndexKey];
    if ([idx isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)idx) {
            if (![item isKindOfClass:NSString.class]) continue;
            NSString *ck = WAGRGateCanonicalKey(item);
            if (!WATOwned(ck) || [seen containsObject:ck]) continue;
            [seen addObject:ck];
            [out addObject:ck];
        }
    }
    NSDictionary *all = [ud dictionaryRepresentation];
    for (NSString *key in all) {
        if (!WATOwned(key) || [seen containsObject:key]) continue;
        if (![all[key] isKindOfClass:NSNumber.class]) continue;
        [seen addObject:key];
        [out addObject:key];
    }
    return out;
}

static void WATSaveKeys(NSUserDefaults *ud, NSArray *keys) {
    [ud setObject:keys ?: @[] forKey:kWATGateOverrideIndexKey];
}

static void WATAddKey(NSUserDefaults *ud, NSString *ck) {
    NSMutableArray *keys = [WATKeys(ud) mutableCopy];
    if (![keys containsObject:ck]) [keys addObject:ck];
    WATSaveKeys(ud, keys);
}

static void WATRemoveKey(NSUserDefaults *ud, NSString *ck) {
    NSMutableArray *keys = [WATKeys(ud) mutableCopy];
    [keys removeObject:ck];
    WATSaveKeys(ud, keys);
}

BOOL WAGRGateIsSet(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    return WATOwned(ck) && [[NSUserDefaults standardUserDefaults] objectForKey:ck] != nil;
}

BOOL WAGRGateGet(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!WATOwned(ck)) return NO;
    return [[[NSUserDefaults standardUserDefaults] objectForKey:ck] boolValue];
}

void WAGRGateSet(NSString *key, BOOL value) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!WATOwned(ck)) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:value forKey:ck];
    WATAddKey(ud, ck);
    [ud synchronize];
}

void WAGRGateClear(NSString *key) {
    NSString *ck = WAGRGateCanonicalKey(key);
    if (!WATOwned(ck)) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:ck];
    WATRemoveKey(ud, ck);
    [ud synchronize];
}

NSArray<NSString *> *WAGRGateAllOverrides(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *ck in WATKeys(ud)) {
        if ([[ud objectForKey:ck] isKindOfClass:NSNumber.class]) [out addObject:WAGRGateDisplayKey(ck)];
    }
    return out;
}

NSUInteger WAGRGateClearAll(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *keys = WAGRGateAllOverrides();
    for (NSString *key in keys) [ud removeObjectForKey:WAGRGateCanonicalKey(key)];
    [ud removeObjectForKey:kWATGateOverrideIndexKey];
    [ud synchronize];
    return keys.count;
}

void WAGRWipeLegacyStorageIfNeeded(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kWAGRStorageWipedMarkerV2]) return;
    NSDictionary *all = [ud dictionaryRepresentation];
    for (NSString *key in all) {
        id obj = all[key];
        BOOL legacyGate = [key hasPrefix:@"wagr.dogfood.gate."] || [key hasPrefix:@"wa_lg_"] || [key isEqualToString:@"wagr_native_debug_menu_enabled"] || [key isEqualToString:@"wagr_internal_master_enabled"];
        if (legacyGate && [obj isKindOfClass:NSNumber.class]) {
            WAGRGateSet(key, [obj boolValue]);
            [ud removeObjectForKey:key];
        }
    }
    [ud setBool:YES forKey:kWAGRStorageWipedMarkerV2];
    [ud synchronize];
}

NSString *WAGRGateStoreDiagnostic(void) {
    return [NSString stringWithFormat:@"schema=v3 watweak canonical\nactive overrides=%lu\nlegacy wipe=%@", (unsigned long)WAGRGateAllOverrides().count, [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRStorageWipedMarkerV2] ? @"done" : @"pending"];
}
