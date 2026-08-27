#import "WAGRMobileConfigInternalPreset.h"
#import "WAGRABPropsRuntime.h"
#import "WAGRABPropsStableIDResolver.h"

static BOOL WAGRMCContainsAny(NSString *name, NSArray<NSString *> *tokens) {
    for (NSString *token in tokens) {
        if ([name containsString:token]) return YES;
    }
    return NO;
}

static NSDictionary<NSNumber *, NSString *> *WAGRMCInternalLiveSelectorIndex(void) {
    NSArray *objects = WAGRABPropsResolveRuntimeObjects(nil);
    NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
    NSMutableDictionary<NSNumber *, NSString *> *index = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in entries) {
        if (entry.classMethod || !entry.selectorName.length) continue;
        NSString *stableID = WAGRABPropsStableIDForTarget(entry.className,
                                                           entry.selectorName,
                                                           entry.classMethod);
        if (!stableID.length) continue;
        NSNumber *key = @([stableID unsignedLongLongValue]);
        NSString *old = index[key];
        if (!old.length || [entry.className containsString:@"WAABProperties"]) {
            index[key] = entry.selectorName;
        }
    }
    return index;
}

static NSString *WAGRMCInternalCombinedName(NSString *liveSelector,
                                             WAGRMobileConfigMapping *mapping) {
    return [NSString stringWithFormat:@"%@ %@ %@",
        liveSelector.lowercaseString ?: @"",
        mapping.configName.lowercaseString ?: @"",
        mapping.parameterName.lowercaseString ?: @""];
}

static BOOL WAGRMCInternalSemanticMatch(NSString *liveSelector,
                                        WAGRMobileConfigMapping *mapping) {
    NSString *combined = WAGRMCInternalCombinedName(liveSelector, mapping);
    if (!combined.length) return NO;

    if (WAGRMCContainsAny(combined, @[
        @"dogfood", @"dogfooding", @"fishfood", @"fishfooding", @"employee"
    ])) return YES;

    if ([combined containsString:@"private_experiment"] ||
        [combined containsString:@"private_abprop"] ||
        [combined containsString:@"whatsbroken"] ||
        [combined containsString:@"what_s_broken"]) return YES;

    if (WAGRMCContainsAny(combined, @[
        @"bug_reporting", @"bug_report", @"bugreport", @"rage_shake", @"rage shake"
    ])) return YES;

    if ([combined containsString:@"internal"]) {
        if (WAGRMCContainsAny(combined, @[
            @"tester", @"test_user", @"test user", @"test_account", @"test account",
            @"settings", @"menu", @"debug", @"bug", @"rage", @"hall",
            @"tool", @"logging", @"indicator", @"developer", @"employee"
        ])) return YES;
    }

    if (WAGRMCContainsAny(combined, @[
        @"test_user", @"test user", @"test_account", @"test account",
        @"internal_tester", @"internal tester"
    ])) return YES;
    return NO;
}

static BOOL WAGRMCInternalDesiredValue(NSString *liveSelector,
                                       WAGRMobileConfigMapping *mapping) {
    NSString *combined = WAGRMCInternalCombinedName(liveSelector, mapping);
    if (WAGRMCContainsAny(combined, @[
        @"disabled", @"disable_", @"_disable", @"kill_switch", @"killswitch",
        @"lockout", @"exclude_employee", @"exclude_employees",
        @"blocked_when_offline", @"remove_setting_switch"
    ])) return NO;
    return YES;
}

static NSString *WAGRMCInternalCategory(NSString *liveSelector,
                                        WAGRMobileConfigMapping *mapping) {
    NSString *combined = WAGRMCInternalCombinedName(liveSelector, mapping);
    if (WAGRMCContainsAny(combined, @[@"bug_report", @"bugreport", @"bug_reporting", @"rage_shake", @"rage shake"])) return @"bug_report_rage_shake";
    if (WAGRMCContainsAny(combined, @[@"dogfood", @"dogfooding", @"fishfood", @"fishfooding"])) return @"dogfood_fishfood";
    if ([combined containsString:@"private_experiment"] || [combined containsString:@"private_abprop"]) return @"private_experimentation";
    if ([combined containsString:@"employee"] || [combined containsString:@"tester"] || [combined containsString:@"test_user"] || [combined containsString:@"test account"] || [combined containsString:@"test_account"]) return @"employee_test";
    if ([combined containsString:@"internal"] || [combined containsString:@"whatsbroken"] || [combined containsString:@"debug"]) return @"internal_debug";
    return @"other_internal";
}

NSDictionary<NSString *, NSArray<NSString *> *> *WAGRMobileConfigInternalPresetDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    NSDictionary<NSString *, id> **stats) {

    NSDictionary<NSNumber *, NSString *> *liveSelectors = WAGRMCInternalLiveSelectorIndex();
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *document = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *categoryCounts = [NSMutableDictionary dictionary];

    NSUInteger considered = 0;
    NSUInteger selected = 0;
    NSUInteger skippedNonBool = 0;
    NSUInteger skippedNotInLiveRuntime = 0;
    NSUInteger skippedUnresolved = 0;
    NSUInteger skippedUnnamed = 0;
    NSUInteger deduplicated = 0;
    NSUInteger falsePolarity = 0;

    for (WAGRMobileConfigMapping *mapping in mappings ?: @[]) {
        if (mapping.nativeType != 1) { skippedNonBool++; continue; }

        NSString *liveSelector = liveSelectors[@(mapping.waStableId)];
        if (!liveSelector.length) {
            skippedNotInLiveRuntime++;
            continue;
        }
        considered++;
        if (!WAGRMCInternalSemanticMatch(liveSelector, mapping)) continue;
        selected++;

        // The live selector establishes that this WA stable ID exists in this
        // installed build. The output identity remains resolver-driven MC:
        // external config stable ID + parameter index.
        if (!mapping.configStableId) { skippedUnresolved++; continue; }
        if (!mapping.configName.length || !mapping.parameterName.length) {
            skippedUnnamed++;
            continue;
        }

        NSString *uid = [NSString stringWithFormat:@"%llu:%u",
            mapping.configStableId, mapping.parameterIndex];
        if ([seen containsObject:uid]) { deduplicated++; continue; }
        [seen addObject:uid];

        BOOL desired = WAGRMCInternalDesiredValue(liveSelector, mapping);
        if (!desired) falsePolarity++;
        NSString *configKey = [NSString stringWithFormat:@"%llu:%@",
            mapping.configStableId, mapping.configName];
        NSString *row = [NSString stringWithFormat:@"%u: %@: %@",
            mapping.parameterIndex,
            mapping.parameterName,
            desired ? @"true" : @"false"];
        NSMutableArray *rows = document[configKey];
        if (!rows) {
            rows = [NSMutableArray array];
            document[configKey] = rows;
        }
        [rows addObject:row];

        NSString *category = WAGRMCInternalCategory(liveSelector, mapping);
        categoryCounts[category] = @([categoryCounts[category] unsignedIntegerValue] + 1);
    }

    [document enumerateKeysAndObjectsUsingBlock:^(__unused NSString *key,
                                                    NSMutableArray<NSString *> *rows,
                                                    __unused BOOL *stop) {
        [rows sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            NSInteger a = [[[left componentsSeparatedByString:@":"] firstObject] integerValue];
            NSInteger b = [[[right componentsSeparatedByString:@":"] firstObject] integerValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return [left localizedCaseInsensitiveCompare:right];
        }];
    }];

    NSUInteger configCount = document.count;
    if (stats) {
        *stats = @{
            @"input_mappings" : @(mappings.count),
            @"live_runtime_stable_ids" : @(liveSelectors.count),
            @"semantic_candidates" : @(considered),
            @"semantic_selected" : @(selected),
            @"emitted" : @(seen.count),
            @"configs" : @(configCount),
            @"negative_polarity_false" : @(falsePolarity),
            @"skipped_non_bool" : @(skippedNonBool),
            @"skipped_not_present_in_current_runtime" : @(skippedNotInLiveRuntime),
            @"skipped_unresolved_external_config_id" : @(skippedUnresolved),
            @"skipped_missing_id_name_mapping_names" : @(skippedUnnamed),
            @"deduplicated" : @(deduplicated),
            @"categories" : categoryCounts,
            @"selector_source" : @"current Objective-C runtime getter -> stable ID decoded from live IMP",
            @"identity" : @"top-level key = FBMobileConfigUserSessionContextManager external config stable ID; row key = parameterIndex",
            @"grammar" : @"<configStableId>:<configName> -> [<parameterIndex>: <parameterName>: <typedValue>] + _qe_overrides_:[]",
        };
    }

    document[@"_qe_overrides_"] = [NSMutableArray array];
    return document;
}

NSData *WAGRMobileConfigInternalPresetJSONData(
    NSDictionary<NSString *, NSArray<NSString *> *> *document,
    NSError **outError) {
    if (!document) return nil;
    NSJSONWritingOptions options = 0;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    return [NSJSONSerialization dataWithJSONObject:document options:options error:outError];
}

NSString *WAGRMobileConfigInternalPresetPolicyDescription(void) {
    return @"Live-runtime preset: discovers selectors from this installed WhatsApp build, decodes their WA stable IDs from getter IMPs, then intersects them with exact UserSession MobileConfig mappings. Internal/Employee/Dogfood/Fishfood/Private Experimentation/Debug/Bug Reporting/Rage Shake are semantic filters only, never fixed selector inventories. Negative-polarity disabled/kill/exclude gates are emitted false. Only BOOL mappings with UserSession external config ID + current config/parameter names are emitted.";
}
