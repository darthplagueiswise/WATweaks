#import "WAGRScopedReset.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "../WAGramPrefix.h"
#import "../WADefaults.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRUserContextLinkage.h"

extern void WAGRLGPrefsDidChange(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRDogfoodEnsureHooksInstalled(void);

typedef NS_ENUM(NSInteger, WAGRResetScope) {
    WAGRResetScopeAll = 0,
    WAGRResetScopeABProps,
    WAGRResetScopeExecutable,
    WAGRResetScopeSharedModules,
    WAGRResetScopeOtherRuntime,
    WAGRResetScopeGateStore,
    WAGRResetScopeDogfood,
    WAGRResetScopeLiquidGlass,
    WAGRResetScopeAura,
};

typedef struct {
    NSUInteger runtimeValues;
    NSUInteger gateValues;
    NSUInteger preferences;
} WAGRResetCounts;

static NSString *WAGRResetUIDForSpec(NSDictionary *spec) {
    NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : nil;
    NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : nil;
    BOOL meta = [spec[@"meta"] boolValue];
    return WAGRRuntimeValueUID(className ?: @"", selector ?: @"", meta);
}

static NSString *WAGRResetImagePathForClass(NSString *className) {
    if (!className.length) return @"";
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    const char *raw = cls ? class_getImageName(cls) : NULL;
    return raw ? ([NSString stringWithUTF8String:raw] ?: @"") : @"";
}

static BOOL WAGRResetIsExecutablePath(NSString *path) {
    if (!path.length) return NO;
    NSString *mainExecutable = NSBundle.mainBundle.executablePath ?: @"";
    if (mainExecutable.length && [path isEqualToString:mainExecutable]) return YES;
    return [path hasSuffix:@"/WhatsApp.app/WhatsApp"] || [path hasSuffix:@"/WhatsApp"];
}

static BOOL WAGRResetIsSharedModulesPath(NSString *path) {
    if (!path.length) return NO;
    if ([path rangeOfString:@"/SharedModules.framework/SharedModules"
                    options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return [path.lastPathComponent caseInsensitiveCompare:@"SharedModules"] == NSOrderedSame;
}

static NSSet<NSString *> *WAGRResetABRuntimeUIDs(void) {
    NSMutableSet<NSString *> *uids = [NSMutableSet set];
    @try {
        id context = WAGRCurrentUserContext();
        NSArray *objects = WAGRABPropsResolveRuntimeObjects(context) ?: @[];
        for (WAGRABPropEntry *entry in WAGRABPropsScan(objects) ?: @[]) {
            NSString *uid = WAGRRuntimeValueUID(entry.className ?: @"",
                                                entry.selectorName ?: @"",
                                                entry.classMethod);
            if (uid.length) [uids addObject:uid];
        }
    } @catch (__unused NSException *exception) {}
    return uids;
}

static BOOL WAGRResetSpecLooksAB(NSDictionary *spec, NSSet<NSString *> *abUIDs) {
    NSString *uid = WAGRResetUIDForSpec(spec);
    if (uid.length && [abUIDs containsObject:uid]) return YES;
    NSString *className = [[spec[@"class"] description] lowercaseString] ?: @"";
    return [className containsString:@"waabproperties"] ||
           [className containsString:@"foawaabproperties"];
}

static BOOL WAGRResetSpecContainsTokens(NSDictionary *spec, NSArray<NSString *> *tokens) {
    NSString *haystack = [NSString stringWithFormat:@"%@ %@",
        spec[@"class"] ?: @"", spec[@"selector"] ?: @""].lowercaseString;
    for (NSString *token in tokens) {
        if (token.length && [haystack containsString:token.lowercaseString]) return YES;
    }
    return NO;
}

static NSUInteger WAGRResetClearRuntimeMatching(BOOL (^matches)(NSDictionary *spec)) {
    NSUInteger removed = 0;
    NSArray<NSDictionary *> *snapshot = WAGRRuntimeValueAllOverrideSpecs();
    for (NSDictionary *spec in snapshot) {
        if (matches && !matches(spec)) continue;
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : nil;
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : nil;
        if (!className.length || !selector.length) continue;
        WAGRRuntimeValueClearOverride(className, selector, [spec[@"meta"] boolValue]);
        removed++;
    }
    return removed;
}

static NSUInteger WAGRResetClearGateMatching(BOOL (^matches)(NSString *displayKey)) {
    NSUInteger removed = 0;
    NSArray<NSString *> *snapshot = WAGRGateAllOverrides();
    for (NSString *storedKey in snapshot) {
        NSString *display = WAGRGateDisplayKey(storedKey) ?: storedKey;
        if (matches && !matches(display ?: @"")) continue;
        WAGRGateClear(storedKey);
        removed++;
    }
    return removed;
}

static NSUInteger WAGRResetRemovePreferenceKeys(NSSet<NSString *> *keys) {
    if (!keys.count) return 0;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSUInteger removed = 0;
    for (NSString *key in keys) {
        if (!key.length || [ud objectForKey:key] == nil) continue;
        [ud removeObjectForKey:key];
        removed++;
    }
    [ud synchronize];
    return removed;
}

static NSUInteger WAGRResetRemovePreferencesMatching(BOOL (^matches)(NSString *key)) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *keys = ud.dictionaryRepresentation.allKeys;
    NSUInteger removed = 0;
    for (NSString *key in keys) {
        if (![key isKindOfClass:NSString.class] || (matches && !matches(key))) continue;
        [ud removeObjectForKey:key];
        removed++;
    }
    [ud synchronize];
    return removed;
}

static NSSet<NSString *> *WAGRResetDogfoodKnownPreferences(void) {
    return [NSSet setWithArray:@[
        WA_PREF_EMPLOYEE_MASTER,
        WA_PREF_EMPLOYEE_SWEEP,
        WA_PREF_EMPLOYEE_SWEEP_OVERRIDES,
        WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP,
        WA_PREF_INTERNAL_TOOLS_SWEEP_BACKUP,
        kWAGRInternalMaster,
        kWAGRDebugMenuNative,
        kWAGRDebugMode,
        kWAGRDogfoodGateMetaEmployee,
        kWAGRDogfoodGateMetaEmployeeSnake,
        kWAGRDogfoodGateInternalUser,
        kWAGRDogfoodGateGraphQLEmpC1,
    ]];
}

static NSMutableSet<NSString *> *WAGRResetDogfoodManagedGateNames(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSString *> *names = [NSMutableSet setWithArray:@[
        @"isInternalUser",
        @"isMetaEmployeeOrInternalTester",
        @"is_meta_employee_or_internal_tester",
        @"graphQLEmployeeC1Disabled",
        @"isDebugMenuAllowed",
        @"isDebugMenuShortcutEnabled",
    ]];
    for (NSString *backupKey in @[WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP,
                                  WA_PREF_INTERNAL_TOOLS_SWEEP_BACKUP]) {
        NSDictionary *backup = [ud dictionaryForKey:backupKey];
        for (id key in backup.allKeys ?: @[]) {
            NSString *name = [key isKindOfClass:NSString.class] ? key : [key description];
            if (name.length) [names addObject:name];
        }
    }
    return names;
}

static NSArray<NSString *> *WAGRResetAuraKeys(void) {
    return @[
        @"aura_enabled", @"aura_settings_row_enabled",
        @"aura_subscription_simulation_enabled", @"aura_app_icon_enabled",
        @"aura_app_themes_enabled", @"aura_ringtones_enabled",
        @"aura_stickers_enabled", @"aura_enhanced_lists_enabled",
        @"aura_pinned_chats_enabled"
    ];
}

static WAGRResetCounts WAGRResetPerform(WAGRResetScope scope) {
    WAGRResetCounts counts = {0, 0, 0};
    NSSet<NSString *> *abUIDs = nil;

    if (scope == WAGRResetScopeAll) {
        counts.runtimeValues += WAGRResetClearRuntimeMatching(nil);
        counts.gateValues += WAGRGateClearAll();

        NSMutableSet<NSString *> *managed = [NSMutableSet setWithArray:WADefaultsDictionary().allKeys];
        [managed addObjectsFromArray:WAGRResetAuraKeys()];
        counts.preferences += WAGRResetRemovePreferenceKeys(managed);
        counts.preferences += WAGRResetRemovePreferencesMatching(^BOOL(NSString *key) {
            return [key hasPrefix:@"watweak_"] || [key hasPrefix:@"watweak."];
        });
        WAGRLGPrefsDidChange();
        return counts;
    }

    if (scope == WAGRResetScopeABProps || scope == WAGRResetScopeExecutable ||
        scope == WAGRResetScopeSharedModules || scope == WAGRResetScopeOtherRuntime) {
        abUIDs = WAGRResetABRuntimeUIDs();
        counts.runtimeValues += WAGRResetClearRuntimeMatching(^BOOL(NSDictionary *spec) {
            BOOL isAB = WAGRResetSpecLooksAB(spec, abUIDs);
            if (scope == WAGRResetScopeABProps) return isAB;
            if (isAB) return NO; // ABProps is its own independent scope.

            NSString *className = [spec[@"class"] description] ?: @"";
            NSString *path = WAGRResetImagePathForClass(className);
            BOOL isExec = WAGRResetIsExecutablePath(path);
            BOOL isShared = WAGRResetIsSharedModulesPath(path);
            if (scope == WAGRResetScopeExecutable) return isExec;
            if (scope == WAGRResetScopeSharedModules) return isShared;
            return !isExec && !isShared;
        });
        return counts;
    }

    if (scope == WAGRResetScopeGateStore) {
        counts.gateValues += WAGRGateClearAll();
        return counts;
    }

    if (scope == WAGRResetScopeDogfood) {
        NSMutableSet<NSString *> *managedNames = WAGRResetDogfoodManagedGateNames();
        counts.gateValues += WAGRResetClearGateMatching(^BOOL(NSString *displayKey) {
            if ([managedNames containsObject:displayKey]) return YES;
            NSString *lower = displayKey.lowercaseString;
            return [lower containsString:@"employee"] ||
                   [lower containsString:@"internaltester"] ||
                   [lower containsString:@"internal_tester"] ||
                   [lower isEqualToString:@"isinternaluser"] ||
                   [lower containsString:@"debugmenu"];
        });
        counts.preferences += WAGRResetRemovePreferenceKeys(WAGRResetDogfoodKnownPreferences());
        counts.runtimeValues += WAGRResetClearRuntimeMatching(^BOOL(NSDictionary *spec) {
            return WAGRResetSpecContainsTokens(spec, @[@"employee", @"internaluser",
                @"internaltester", @"internal_tester", @"dogfood", @"fishfood", @"debugmenu"]);
        });
        WAGRDogfoodEnsureHooksInstalled();
        return counts;
    }

    if (scope == WAGRResetScopeLiquidGlass) {
        counts.preferences += WAGRResetRemovePreferenceKeys([NSSet setWithArray:@[
            WA_PREF_LIQUID_GLASS,
            WA_PREF_LIQUID_GLASS_USERDEFAULTS,
            WA_PREF_LIQUID_GLASS_METHOD_HOOKS,
        ]]);
        counts.gateValues += WAGRResetClearGateMatching(^BOOL(NSString *displayKey) {
            NSString *lower = displayKey.lowercaseString;
            return [lower containsString:@"liquid_glass"] || [lower containsString:@"liquidglass"];
        });
        counts.runtimeValues += WAGRResetClearRuntimeMatching(^BOOL(NSDictionary *spec) {
            return WAGRResetSpecContainsTokens(spec, @[@"liquid_glass", @"liquidglass"]);
        });
        // This also removes the concrete ios_liquid_glass_* defaults written by
        // WAGRLiquidGlassHooks when the master becomes OFF.
        WAGRLGPrefsDidChange();
        return counts;
    }

    if (scope == WAGRResetScopeAura) {
        NSMutableSet<NSString *> *prefs = [NSMutableSet setWithArray:WAGRResetAuraKeys()];
        [prefs addObject:kWAGRAuraSimulation];
        counts.preferences += WAGRResetRemovePreferenceKeys(prefs);
        counts.gateValues += WAGRResetClearGateMatching(^BOOL(NSString *displayKey) {
            return [displayKey.lowercaseString containsString:@"aura"];
        });
        counts.runtimeValues += WAGRResetClearRuntimeMatching(^BOOL(NSDictionary *spec) {
            return WAGRResetSpecContainsTokens(spec, @[@"aura"]);
        });
        WAGRAuraEnsureHooksInstalled();
        return counts;
    }

    return counts;
}

static NSString *WAGRResetScopeTitle(WAGRResetScope scope) {
    switch (scope) {
        case WAGRResetScopeAll: return @"Tudo do WATweaks";
        case WAGRResetScopeABProps: return @"Somente ABProps";
        case WAGRResetScopeExecutable: return @"Runtime · WhatsApp Executable";
        case WAGRResetScopeSharedModules: return @"Runtime · SharedModules";
        case WAGRResetScopeOtherRuntime: return @"Runtime · Outros frameworks";
        case WAGRResetScopeGateStore: return @"Somente GateStore";
        case WAGRResetScopeDogfood: return @"Dogfood / Internal";
        case WAGRResetScopeLiquidGlass: return @"Liquid Glass";
        case WAGRResetScopeAura: return @"Aura / WA Plus";
    }
}

static void WAGRResetShowResult(UIViewController *presenter,
                                WAGRResetScope scope,
                                WAGRResetCounts counts) {
    NSString *message = [NSString stringWithFormat:
        @"Runtime overrides removidos: %lu\nGateStore removidos: %lu\nPreferências removidas: %lu\n\nOs hooks já instalados passam a usar o valor original quando o override some. Reiniciar garante que caches do WhatsApp também sejam reconstruídos.",
        (unsigned long)counts.runtimeValues,
        (unsigned long)counts.gateValues,
        (unsigned long)counts.preferences];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:WAGRResetScopeTitle(scope)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"Reiniciar WhatsApp"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [done addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:done animated:YES completion:nil];
}

static void WAGRResetConfirm(UIViewController *presenter, WAGRResetScope scope) {
    NSString *title = WAGRResetScopeTitle(scope);
    NSString *message = scope == WAGRResetScopeAll
        ? @"Remove todos os overrides e preferências gerenciados pelo WATweaks. Não toca no cache nativo gabp.* do WhatsApp."
        : @"Remove somente este escopo. Os demais overrides permanecem intactos.";
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Remover"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(__unused UIAlertAction *action) {
        WAGRResetCounts counts = WAGRResetPerform(scope);
        WAGRResetShowResult(presenter, scope, counts);
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

void WAGRPresentScopedReset(UIViewController *presenter) {
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Remover tweaks"
                                                                    message:@"Escolha exatamente o que deve ser removido."
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSDictionary *> *rows = @[
        @{@"title": @"Tudo do WATweaks", @"scope": @(WAGRResetScopeAll)},
        @{@"title": @"Somente ABProps", @"scope": @(WAGRResetScopeABProps)},
        @{@"title": @"Runtime · WhatsApp Executable", @"scope": @(WAGRResetScopeExecutable)},
        @{@"title": @"Runtime · SharedModules", @"scope": @(WAGRResetScopeSharedModules)},
        @{@"title": @"Runtime · Outros frameworks", @"scope": @(WAGRResetScopeOtherRuntime)},
        @{@"title": @"Somente GateStore", @"scope": @(WAGRResetScopeGateStore)},
        @{@"title": @"Dogfood / Internal", @"scope": @(WAGRResetScopeDogfood)},
        @{@"title": @"Liquid Glass", @"scope": @(WAGRResetScopeLiquidGlass)},
        @{@"title": @"Aura / WA Plus", @"scope": @(WAGRResetScopeAura)},
    ];
    for (NSDictionary *row in rows) {
        WAGRResetScope scope = (WAGRResetScope)[row[@"scope"] integerValue];
        UIAlertActionStyle style = scope == WAGRResetScopeAll
            ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        [sheet addAction:[UIAlertAction actionWithTitle:row[@"title"]
                                                  style:style
                                                handler:^(__unused UIAlertAction *action) {
            WAGRResetConfirm(presenter, scope);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = presenter.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                        CGRectGetMaxY(presenter.view.bounds) - 1.0, 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}
