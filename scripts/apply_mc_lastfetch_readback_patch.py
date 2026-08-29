#!/usr/bin/env python3
from pathlib import Path

engine_path = Path("src/Runtime/WAGRMobileConfigNativeEngine.m")
validator_path = Path("scripts/wagr_validate_abprops_fetch.py")

text = engine_path.read_text()
anchor = '''static BOOL WAGRMCNativeStringsDescribeEqual(id left, id right) {
    if (!left || !right) return NO;
    NSString *a = [left isKindOfClass:NSString.class] ? left : [left description];
    NSString *b = [right isKindOfClass:NSString.class] ? right : [right description];
    return a.length && b.length && [a isEqualToString:b];
}
'''
helpers = r'''

static BOOL WAGRMCNativeArgumentIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRMCNativeSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCNativeArgumentIsInt32(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRMCNativeSkipQualifiers(raw);
    return type[0] == 'i' || type[0] == 'I';
}

static NSString *WAGRMCNativeLastFetchPreferenceKey(Class cls,
                                                     NSString *selectorName,
                                                     int unitType,
                                                     id unitId) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRMCNativeMethodReturnsObject(method) ||
        !WAGRMCNativeArgumentIsInt32(method, 2) ||
        !WAGRMCNativeArgumentIsObject(method, 3)) return nil;
    @try {
        id value = ((id (*)(id, SEL, int, id))objc_msgSend)((id)cls, selector, unitType, unitId);
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id WAGRMCNativePreferenceObject(id store, NSString *key) {
    if (!store || !key.length) return nil;
    for (NSString *selectorName in @[@"objectForKey:", @"objectForKeyedSubscript:"]) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getInstanceMethod([store class], selector);
        if (!method || method_getNumberOfArguments(method) != 3 ||
            !WAGRMCNativeMethodReturnsObject(method) ||
            !WAGRMCNativeArgumentIsObject(method, 2)) continue;
        @try {
            return ((id (*)(id, SEL, id))objc_msgSend)(store, selector, key);
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static NSDictionary *WAGRMCNativeLastFetchPersistenceReadback(id preferencesStore,
                                                               int unitType,
                                                               id unitId,
                                                               id appVersion) {
    Class cls = NSClassFromString(@"WAMobileConfigLastFetchStore") ?: objc_getClass("WAMobileConfigLastFetchStore");
    NSString *fetchKey = WAGRMCNativeLastFetchPreferenceKey(
        cls, @"preferenceKeyForLastSuccessFetch:unitId:", unitType, unitId);
    NSString *versionKey = WAGRMCNativeLastFetchPreferenceKey(
        cls, @"preferenceKeyForLastSuccessFetchAppVersion:unitId:", unitType, unitId);
    id fetchValue = WAGRMCNativePreferenceObject(preferencesStore, fetchKey);
    id versionValue = WAGRMCNativePreferenceObject(preferencesStore, versionKey);
    BOOL fetchPresent = fetchKey.length && fetchValue != nil;
    BOOL versionPresent = versionKey.length && versionValue != nil;
    BOOL versionMatches = !appVersion || (versionPresent && WAGRMCNativeStringsDescribeEqual(versionValue, appVersion));
    BOOL verified = fetchPresent && versionMatches;
    return @{
        @"fetch_preference_key" : fetchKey ?: (id)NSNull.null,
        @"fetch_preference_value" : fetchValue ?: (id)NSNull.null,
        @"fetch_marker_present" : @(fetchPresent),
        @"app_version_preference_key" : versionKey ?: (id)NSNull.null,
        @"app_version_preference_value" : versionValue ?: (id)NSNull.null,
        @"app_version_marker_present" : @(versionPresent),
        @"app_version_matches" : @(versionMatches),
        @"persistent_success_marker_verified" : @(verified),
        @"policy" : @"Keys are resolved by WAMobileConfigLastFetchStore itself after its native setter returns; WATweaks does not synthesize mobileconfig2_* preference names."
    };
}
'''
if helpers.strip() not in text:
    if anchor not in text:
        raise SystemExit("engine helper anchor missing")
    text = text.replace(anchor, anchor + helpers, 1)

old = '''    NSDictionary *file = WAGRMCNativeFileState(WAGRMCNativeLatestConfigPath(WAGRCurrentUserContext()));
    WAGRMCNativeFinishFetch(token, @{
        @"state" : @"verified_native_success_marker",
        @"verified_server_response" : @YES,
        @"success_marker" : @{
            @"class" : NSStringFromClass([self class]) ?: @"?",
            @"unit_type" : @(unitType),
            @"unit_id" : unitId ? ([unitId description] ?: @"?") : (id)NSNull.null,
            @"app_version" : appVersion ? ([appVersion description] ?: @"?") : (id)NSNull.null,
            @"preferences_store_class" : preferencesStore ? (NSStringFromClass([preferencesStore class]) ?: @"?") : @"nil"
        },
        @"network_input" : backend ?: @{},
        @"latest_config_after" : file ?: @{}
    });
'''
new = '''    NSDictionary *file = WAGRMCNativeFileState(WAGRMCNativeLatestConfigPath(WAGRCurrentUserContext()));
    NSDictionary *persistentMarker = WAGRMCNativeLastFetchPersistenceReadback(
        preferencesStore, unitType, unitId, appVersion);
    BOOL persistentVerified = [persistentMarker[@"persistent_success_marker_verified"] boolValue];
    WAGRMCNativeFinishFetch(token, @{
        @"state" : persistentVerified ? @"verified_native_persisted_success_marker" : @"verified_native_success_marker",
        @"verified_server_response" : @YES,
        @"persistent_success_marker_verified" : @(persistentVerified),
        @"success_marker" : @{
            @"class" : NSStringFromClass([self class]) ?: @"?",
            @"unit_type" : @(unitType),
            @"unit_id" : unitId ? ([unitId description] ?: @"?") : (id)NSNull.null,
            @"app_version" : appVersion ? ([appVersion description] ?: @"?") : (id)NSNull.null,
            @"preferences_store_class" : preferencesStore ? (NSStringFromClass([preferencesStore class]) ?: @"?") : @"nil",
            @"persistence_readback" : persistentMarker ?: @{}
        },
        @"network_input" : backend ?: @{},
        @"latest_config_after" : file ?: @{}
    });
'''
if old not in text:
    raise SystemExit("success marker block missing")
text = text.replace(old, new, 1)
engine_path.write_text(text)

v = validator_path.read_text()
old_v = '''        "setLastSuccessFetchInPreferencesStore:unitType:unitId:appVersion:",
        "v44@0:8@16i24@28@36",
        "verified_server_response",
'''
new_v = '''        "setLastSuccessFetchInPreferencesStore:unitType:unitId:appVersion:",
        "v44@0:8@16i24@28@36",
        "preferenceKeyForLastSuccessFetch:unitId:",
        "preferenceKeyForLastSuccessFetchAppVersion:unitId:",
        "persistent_success_marker_verified",
        "verified_native_persisted_success_marker",
        "verified_server_response",
'''
if old_v not in v:
    raise SystemExit("validator MC marker block missing")
v = v.replace(old_v, new_v, 1)
validator_path.write_text(v)
