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

NSString * const kWAGRStorageWipedMarkerV2 = @"wagr.storage.wiped.v2";

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

static BOOL WAGRKeyIsGateOverride(NSString *key) {
    // A gate override key is anything that is NOT in the reserved wagr.* /
    // wagr_* namespace and NOT a known WAPrefix.h-style master pref. We use a
    // simple negative test because gate keys are selectors and flag names —
    // they never start with wagr.
    if (!key.length) return NO;
    if ([key hasPrefix:@"wagr."]) return NO;
    if ([key hasPrefix:@"wagr_"]) return NO;
    // Apple-reserved domains (skip Apple system keys so we never touch them).
    if ([key hasPrefix:@"Apple"] || [key hasPrefix:@"NS"]) return NO;
    return YES;
}

// ── Accessors ────────────────────────────────────────────────────────────────
BOOL WAGRGateIsSet(NSString *key) {
    if (!key.length) return NO;
    return [[NSUserDefaults standardUserDefaults] objectForKey:key] != nil;
}

BOOL WAGRGateGet(NSString *key) {
    if (!key.length) return NO;
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return obj ? [obj boolValue] : NO;
}

void WAGRGateSet(NSString *key, BOOL value) {
    if (!key.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:value forKey:key];
    [ud synchronize];
}

void WAGRGateClear(NSString *key) {
    if (!key.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:key];
    [ud synchronize];
}

NSArray<NSString *> *WAGRGateAllOverrides(void) {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *key in all) {
        if (![key isKindOfClass:NSString.class]) continue;
        if (!WAGRKeyIsGateOverride(key)) continue;
        id obj = all[key];
        // Only count keys that are plausibly gate overrides (numbers/bools).
        // Strings/arrays/dicts here are noise from other apps' suites that
        // sometimes spill into the standard defaults.
        if (![obj isKindOfClass:NSNumber.class]) continue;
        [out addObject:key];
    }
    return out;
}

NSUInteger WAGRGateClearAll(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *keys = WAGRGateAllOverrides();
    for (NSString *key in keys) [ud removeObjectForKey:key];
    [ud synchronize];
    return keys.count;
}

// ── Wipe ─────────────────────────────────────────────────────────────────────
void WAGRWipeLegacyStorageIfNeeded(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kWAGRStorageWipedMarkerV2]) return;

    NSArray<NSString *> *prefixes = WAGRLegacyKeyPrefixes();
    NSDictionary *all = [ud dictionaryRepresentation];
    NSUInteger removed = 0;
    for (NSString *key in all) {
        if (![key isKindOfClass:NSString.class]) continue;
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
    NSLog(@"[WATweaks][Store] legacy wipe removed %lu keys (schema v2 marker set)",
          (unsigned long)removed);
}

NSString *WAGRGateStoreDiagnostic(void) {
    return [NSString stringWithFormat:
        @"schema=v2 (selector-name keys)\nactive overrides=%lu\nlegacy wipe=%@",
        (unsigned long)WAGRGateAllOverrides().count,
        [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRStorageWipedMarkerV2] ? @"done" : @"pending"];
}
