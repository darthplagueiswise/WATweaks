#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

#pragma mark - ABI helpers

static const char *WAGRABMCSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABMCMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABMCSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABMCMethodReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRABMCSkipQualifiers(raw)[0]) {
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
            return YES;
        default:
            return NO;
    }
}

static BOOL WAGRABMCMethodArgumentFitsWord(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRABMCSkipQualifiers(raw);
    if (!*type) return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static id WAGRABMCCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABMCMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABMCCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABMCMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRABMCCallOptionalBoolNoArg(id target,
                                          NSString *selectorName,
                                          BOOL *implemented) {
    if (implemented) *implemented = NO;
    if (!target || !selectorName.length) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABMCMethodReturnsInteger(method)) return NO;
    if (implemented) *implemented = YES;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return NO; }
}

#pragma mark - Deterministic manager resolution

static BOOL WAGRABMCManagerUsable(id manager) {
    if (!manager) return NO;
    NSString *className = NSStringFromClass([manager class]) ?: @"";
    if (![className containsString:@"FBMobileConfigContextManager"]) return NO;

    BOOL hasValidManager = NO, hasValidConfig = NO;
    BOOL validManager = WAGRABMCCallOptionalBoolNoArg(manager, @"hasValidManager", &hasValidManager);
    BOOL validConfig = WAGRABMCCallOptionalBoolNoArg(manager, @"hasValidConfig", &hasValidConfig);
    if (hasValidManager && !validManager) return NO;
    if (hasValidConfig && !validConfig) return NO;
    return YES;
}

static void WAGRABMCPrimeBridgeWithManager(id manager) {
    if (!WAGRABMCManagerUsable(manager)) return;
    WAGRMobileConfigEnsureCaptureHooksInstalled();
    // getOverridesTablePath is already transparently hooked by the bridge. Calling
    // it here does not mutate MC state; it only guarantees the live manager is
    // captured before the AB -> MC screen or export asks for it.
    (void)WAGRABMCCallObjectNoArg(manager, @"getOverridesTablePath");
}

static id WAGRABMCResolveManager(void) {
    WAGRMobileConfigEnsureCaptureHooksInstalled();

    id manager = WAGRMobileConfigContextManager(WAGRCurrentUserContext());
    if (WAGRABMCManagerUsable(manager)) return manager;

    Class cls = NSClassFromString(@"FBMobileConfigContextManager");
    for (NSString *selectorName in @[
        @"sessionlessContextManager",
        @"defaultValueContextManager",
        @"defaultContextManager",
        @"currentContextManager"
    ]) {
        id candidate = WAGRABMCCallClassObjectNoArg(cls, selectorName);
        if (!WAGRABMCManagerUsable(candidate)) continue;
        WAGRABMCPrimeBridgeWithManager(candidate);
        id captured = WAGRMobileConfigContextManager(WAGRCurrentUserContext());
        return WAGRABMCManagerUsable(captured) ? captured : candidate;
    }
    return nil;
}

#pragma mark - Stable-ID and native name resolution

static uint64_t WAGRABMCExternalStableId(id manager, uint64_t specifier) {
    if (!manager || !specifier) return 0;
    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABMCMethodArgumentFitsWord(method, 2)) return 0;

    @try {
        if (WAGRABMCMethodReturnsObject(method)) {
            id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            if ([value respondsToSelector:@selector(unsignedLongLongValue)]) {
                return [value unsignedLongLongValue];
            }
            return strtoull([[value description] UTF8String] ?: "0", NULL, 10);
        }
        if (WAGRABMCMethodReturnsInteger(method)) {
            return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
        }
    } @catch (__unused NSException *exception) {}
    return 0;
}

static NSString *WAGRABMCEmbeddedName(uint64_t specifier) {
    if (!specifier) return nil;
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs");
    id instance = WAGRABMCCallClassObjectNoArg(cls, @"getInstance");
    if (!instance) return nil;

    SEL selector = NSSelectorFromString(@"convertSpecifierToParamName:");
    Method method = class_getInstanceMethod([instance class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABMCMethodReturnsObject(method) ||
        !WAGRABMCMethodArgumentFitsWord(method, 2)) return nil;

    @try {
        id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(instance, selector, specifier);
        return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void WAGRABMCSplitEmbeddedName(NSString *fullName,
                                      NSString **configName,
                                      NSString **parameterName) {
    if (configName) *configName = nil;
    if (parameterName) *parameterName = nil;
    if (!fullName.length) return;

    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0 &&
        NSMaxRange(dot) < fullName.length) {
        if (configName) *configName = [fullName substringToIndex:dot.location];
        if (parameterName) *parameterName = [fullName substringFromIndex:NSMaxRange(dot)];
    } else if (parameterName) {
        *parameterName = fullName;
    }
}

static uint64_t WAGRABMCSpecifierFromEntry(NSDictionary *mc) {
    NSString *hex = [mc[@"param_specifier_hex"] isKindOfClass:NSString.class]
        ? mc[@"param_specifier_hex"] : nil;
    if (!hex.length) return 0;
    const char *cursor = hex.UTF8String;
    if (!cursor) return 0;
    return strtoull(cursor, NULL, 0);
}

#pragma mark - Snapshot/export enrichment

static NSDictionary *WAGRABMCEnrichDocument(NSDictionary *document) {
    if (![document isKindOfClass:NSDictionary.class]) return document ?: @{};

    id manager = WAGRABMCResolveManager();
    NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class]
        ? document[@"entries"] : @[];
    NSMutableArray *resolvedEntries = [NSMutableArray arrayWithCapacity:entries.count];
    NSUInteger translated = 0, externalResolved = 0, named = 0;

    for (id item in entries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry = [item mutableCopy];
        NSDictionary *rawMC = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? entry[@"mobileconfig"] : nil;
        if (!rawMC) {
            [resolvedEntries addObject:entry];
            continue;
        }

        translated++;
        NSMutableDictionary *mc = [rawMC mutableCopy];
        id legacyToken = mc[@"parameter_stable_id"];
        if (legacyToken && !mc[@"compact_parameter_token"]) {
            mc[@"compact_parameter_token"] = legacyToken;
        }
        [mc removeObjectForKey:@"parameter_stable_id"];

        uint64_t specifier = WAGRABMCSpecifierFromEntry(mc);
        if (manager && specifier) {
            uint64_t externalId = WAGRABMCExternalStableId(manager, specifier);
            if (externalId) {
                mc[@"external_config_stable_id"] = @(externalId);
                externalResolved++;
            }

            NSString *configName = nil, *parameterName = nil;
            WAGRABMCSplitEmbeddedName(WAGRABMCEmbeddedName(specifier),
                                      &configName, &parameterName);
            if (configName.length) mc[@"config_name"] = configName;
            if (parameterName.length) mc[@"parameter_name"] = parameterName;
            if (configName.length || parameterName.length) named++;
        }
        entry[@"mobileconfig"] = mc;
        [resolvedEntries addObject:entry];
    }

    NSMutableDictionary *result = [document mutableCopy];
    result[@"format"] = @"WATweaks WhatsApp native ABProps snapshot v2";
    result[@"entries"] = resolvedEntries;
    result[@"mobileconfig_resolution"] = @{
        @"manager" : manager ? NSStringFromClass([manager class]) : @"unavailable",
        @"translated_entries" : @(translated),
        @"external_config_ids_resolved" : @(externalResolved),
        @"native_names_resolved" : @(named),
        @"mc_overrides_path" : WAGRMobileConfigOverridesPath(WAGRCurrentUserContext()) ?: NSNull.null,
        @"id_name_mapping_path" : WAGRMobileConfigNamesPath(WAGRCurrentUserContext()) ?: NSNull.null,
    };
    WAGRLogAppendF(@"[ABProps][MC] snapshot translated=%lu external=%lu nativeNames=%lu manager=%@",
                   (unsigned long)translated, (unsigned long)externalResolved,
                   (unsigned long)named,
                   manager ? NSStringFromClass([manager class]) : @"nil");
    return result;
}

static void (*orig_WAGRABMCReloadLocalSnapshot)(id, SEL) = NULL;
static UITableViewCell *(*orig_WAGRABMCCellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL gWAGRABMCReloadHooked = NO;
static BOOL gWAGRABMCCellHooked = NO;

static void hook_WAGRABMCReloadLocalSnapshot(id self, SEL _cmd) {
    if (orig_WAGRABMCReloadLocalSnapshot) orig_WAGRABMCReloadLocalSnapshot(self, _cmd);

    NSDictionary *document = nil;
    @try { document = [self valueForKey:@"exportDocument"]; }
    @catch (__unused NSException *exception) { document = nil; }
    if (!document.count) return;

    NSDictionary *enriched = WAGRABMCEnrichDocument(document);
    NSArray *entries = [enriched[@"entries"] isKindOfClass:NSArray.class]
        ? enriched[@"entries"] : @[];
    @try {
        [self setValue:enriched forKey:@"exportDocument"];
        [self setValue:entries forKey:@"allEntries"];
        SEL applyFilter = NSSelectorFromString(@"applyFilter");
        if ([self respondsToSelector:applyFilter]) {
            ((void (*)(id, SEL))objc_msgSend)(self, applyFilter);
        }
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][MC] snapshot enrichment failed: %@",
                       exception.reason ?: @"exception");
    }
}

static UITableViewCell *hook_WAGRABMCCellForRow(id self,
                                                 SEL _cmd,
                                                 UITableView *tableView,
                                                 NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_WAGRABMCCellForRow
        ? orig_WAGRABMCCellForRow(self, _cmd, tableView, indexPath) : nil;
    if (!cell || !indexPath) return cell;

    NSArray *visible = nil;
    @try { visible = [self valueForKey:@"visibleEntries"]; }
    @catch (__unused NSException *exception) { visible = nil; }
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= visible.count) return cell;
    NSDictionary *entry = [visible[(NSUInteger)indexPath.row] isKindOfClass:NSDictionary.class]
        ? visible[(NSUInteger)indexPath.row] : nil;
    NSDictionary *mc = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? entry[@"mobileconfig"] : nil;
    id external = mc[@"external_config_stable_id"];
    if (!external) return cell;

    NSString *config = [mc[@"config_name"] isKindOfClass:NSString.class] ? mc[@"config_name"] : nil;
    NSString *parameter = [mc[@"parameter_name"] isKindOfClass:NSString.class] ? mc[@"parameter_name"] : nil;
    NSString *resolvedName = nil;
    if (config.length && parameter.length) resolvedName = [NSString stringWithFormat:@"%@.%@", config, parameter];
    else resolvedName = config.length ? config : parameter;

    NSString *extra = resolvedName.length
        ? [NSString stringWithFormat:@"MC external=%@ · %@", external, resolvedName]
        : [NSString stringWithFormat:@"MC external=%@", external];
    NSString *current = cell.detailTextLabel.text ?: @"";
    if (![current containsString:@"MC external="]) {
        cell.detailTextLabel.text = current.length
            ? [current stringByAppendingFormat:@"\n%@", extra] : extra;
        cell.detailTextLabel.numberOfLines = 5;
    }
    return cell;
}

static void WAGRABMCInstallSnapshotHooks(void) {
    Class cls = NSClassFromString(@"WAGRABPropsSnapshotVC");
    if (!cls) return;

    @synchronized (cls) {
        if (!gWAGRABMCReloadHooked) {
            SEL selector = NSSelectorFromString(@"reloadLocalSnapshot");
            Method method = class_getInstanceMethod(cls, selector);
            if (method && method_getNumberOfArguments(method) == 2) {
                MSHookMessageEx(cls, selector, (IMP)hook_WAGRABMCReloadLocalSnapshot,
                                (IMP *)&orig_WAGRABMCReloadLocalSnapshot);
                gWAGRABMCReloadHooked = (orig_WAGRABMCReloadLocalSnapshot != NULL);
            }
        }
        if (!gWAGRABMCCellHooked) {
            SEL selector = @selector(tableView:cellForRowAtIndexPath:);
            Method method = class_getInstanceMethod(cls, selector);
            if (method && method_getNumberOfArguments(method) == 4 &&
                WAGRABMCMethodReturnsObject(method)) {
                MSHookMessageEx(cls, selector, (IMP)hook_WAGRABMCCellForRow,
                                (IMP *)&orig_WAGRABMCCellForRow);
                gWAGRABMCCellHooked = (orig_WAGRABMCCellForRow != NULL);
            }
        }
    }
}

__attribute__((constructor))
static void WAGRABPropsExternalMCEnrichmentCtor(void) {
    @autoreleasepool {
        WAGRMobileConfigEnsureCaptureHooksInstalled();
        (void)WAGRABMCResolveManager();
        WAGRABMCInstallSnapshotHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            (void)WAGRABMCResolveManager();
            WAGRABMCInstallSnapshotHooks();
        });
    }
}
