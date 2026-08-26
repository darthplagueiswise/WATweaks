#import "WAGRMobileConfigInternalPreset.h"
#import "WAGRABPropsCanonicalNamesV2.h"

static NSSet<NSString *> *WAGRMCInternalExactSelectors(void) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"is_meta_employee_or_internal_tester",
            @"is_internal_tester",
            @"waios_mc_debug_ui_enabled",
            @"whatsbroken_enabled",
            @"private_abprop_for_dev_only",
            @"private_experimentation_should_sync",
            @"private_experimentation_use_acs_config_id",
            @"dogfooding_nudge_settings_entrypoint_enabled",
            @"dogfooding_nudge_banner_home_screen_enabled",
            @"username_dogfooding_pn_privacy_enabled",
            @"username_dogfooding_pn_privacy_periodic_conversion_enabled",
            @"tbv_pass_eligibility_dogfooding_gk",
            @"get_help_internal_bug_report_enabled",
            @"give_dogfooders_task_id_for_bug_reporting",
            @"internal_bug_reporting_bottom_sheet",
            @"ios_internal_in_app_bug_reporting_enable",
            @"ios_internal_rage_shake_enabled",
            @"ios_internal_hall_enabled",
            @"hn_dogfooding",
            @"malibu_dogfooding",
            @"graphQLEmployeeC1Disabled",
            @"rage_shake_eligible_via_bug_form",
            @"show_fishfooding_toggle_in_bug_reporting_form",
            @"bug_reporting_attach_pathfinder_pre_bug_creation",
            @"bug_reporting_abprops_uploaded_on_submissoin"
        ]];
    });
    return set;
}

static BOOL WAGRMCContainsAny(NSString *name, NSArray<NSString *> *tokens) {
    for (NSString *token in tokens) {
        if ([name containsString:token]) return YES;
    }
    return NO;
}

static BOOL WAGRMCInternalSemanticMatch(NSString *canonicalName,
                                        NSString *parameterName) {
    NSString *name = canonicalName.lowercaseString ?: @"";
    NSString *param = parameterName.lowercaseString ?: @"";
    NSString *combined = [NSString stringWithFormat:@"%@ %@", name, param];
    if ([WAGRMCInternalExactSelectors() containsObject:name]) return YES;

    // Dogfood/fishfood/employee flags are intrinsically internal cohort gates.
    if (WAGRMCContainsAny(combined, @[
        @"dogfood", @"dogfooding", @"fishfood", @"fishfooding", @"employee"
    ])) return YES;

    // Private experimentation and internal QA/debug surfaces.
    if ([combined containsString:@"private_experimentation"] ||
        [combined containsString:@"private_abprop_for_dev_only"] ||
        [combined containsString:@"whatsbroken"]) return YES;

    // Bug-report / rage-shake infrastructure requested for the internal preset.
    if (WAGRMCContainsAny(combined, @[
        @"bug_reporting", @"bug_report", @"rage_shake", @"rage shake"
    ])) return YES;

    // "internal" alone is too broad. Restrict it to tooling/test/settings/debug
    // semantics so unrelated production features are not enabled accidentally.
    if ([combined containsString:@"internal"]) {
        if (WAGRMCContainsAny(combined, @[
            @"tester", @"test_user", @"test user", @"test_account", @"test account",
            @"settings", @"menu", @"debug", @"bug", @"rage", @"hall",
            @"tool", @"logging", @"indicator", @"developer"
        ])) return YES;
    }

    // Explicit test-user/test-account cohort gates without broad matching on
    // every feature containing the word "test".
    if (WAGRMCContainsAny(combined, @[
        @"test_user", @"test user", @"test_account", @"test account",
        @"internal_tester", @"internal tester"
    ])) return YES;

    return NO;
}

static BOOL WAGRMCInternalDesiredValue(NSString *canonicalName,
                                       NSString *parameterName) {
    NSString *combined = [NSString stringWithFormat:@"%@ %@",
        canonicalName.lowercaseString ?: @"",
        parameterName.lowercaseString ?: @""];

    // Negative polarity gates must remain false in an enable-internal preset.
    if (WAGRMCContainsAny(combined, @[
        @"disabled", @"disable_", @"_disable", @"kill_switch", @"killswitch",
        @"lockout", @"exclude_employee", @"exclude_employees",
        @"blocked_when_offline", @"remove_setting_switch"
    ])) return NO;
    return YES;
}

static NSString *WAGRMCInternalCategory(NSString *canonicalName,
                                        NSString *parameterName) {
    NSString *combined = [NSString stringWithFormat:@"%@ %@",
        canonicalName.lowercaseString ?: @"",
        parameterName.lowercaseString ?: @""];
    if (WAGRMCContainsAny(combined, @[@"bug_report", @"bug_reporting", @"rage_shake", @"rage shake"])) return @"bug_report_rage_shake";
    if (WAGRMCContainsAny(combined, @[@"dogfood", @"dogfooding", @"fishfood", @"fishfooding"])) return @"dogfood_fishfood";
    if ([combined containsString:@"private_experimentation"] || [combined containsString:@"private_abprop"]) return @"private_experimentation";
    if ([combined containsString:@"employee"] || [combined containsString:@"tester"] || [combined containsString:@"test_user"] || [combined containsString:@"test account"] || [combined containsString:@"test_account"]) return @"employee_test";
    if ([combined containsString:@"internal"] || [combined containsString:@"whatsbroken"] || [combined containsString:@"debug"]) return @"internal_debug";
    return @"other_internal";
}

NSDictionary<NSString *, NSArray<NSString *> *> *WAGRMobileConfigInternalPresetDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    NSDictionary<NSString *, id> **stats) {

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *document = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *categoryCounts = [NSMutableDictionary dictionary];

    NSUInteger considered = 0;
    NSUInteger selected = 0;
    NSUInteger skippedNonBool = 0;
    NSUInteger skippedUnresolved = 0;
    NSUInteger skippedUnnamed = 0;
    NSUInteger deduplicated = 0;
    NSUInteger falsePolarity = 0;

    for (WAGRMobileConfigMapping *mapping in mappings ?: @[]) {
        if (mapping.nativeType != 1) { skippedNonBool++; continue; }
        NSString *canonical = WAGRABPropsCanonicalNameForCode(
            [NSString stringWithFormat:@"%lu", (unsigned long)mapping.waStableId]);
        if (!canonical.length && !mapping.parameterName.length) continue;
        considered++;
        if (!WAGRMCInternalSemanticMatch(canonical, mapping.parameterName)) continue;
        selected++;

        // Grammar must be based on resolved MobileConfig identity. Never emit a
        // WA stable ID, localConfigIndex or compact token as the top-level key.
        if (!mapping.configStableId) { skippedUnresolved++; continue; }

        // The user's reference grammar carries semantic names in both levels.
        // Do not invent names when id_name_mapping has not resolved them.
        if (!mapping.configName.length || !mapping.parameterName.length) {
            skippedUnnamed++;
            continue;
        }

        NSString *uid = [NSString stringWithFormat:@"%llu:%u",
            mapping.configStableId, mapping.parameterIndex];
        if ([seen containsObject:uid]) { deduplicated++; continue; }
        [seen addObject:uid];

        BOOL desired = WAGRMCInternalDesiredValue(canonical, mapping.parameterName);
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

        NSString *category = WAGRMCInternalCategory(canonical, mapping.parameterName);
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

    if (stats) {
        *stats = @{
            @"input_mappings" : @(mappings.count),
            @"semantic_candidates" : @(considered),
            @"semantic_selected" : @(selected),
            @"emitted" : @(seen.count),
            @"configs" : @(document.count),
            @"negative_polarity_false" : @(falsePolarity),
            @"skipped_non_bool" : @(skippedNonBool),
            @"skipped_unresolved_external_config_id" : @(skippedUnresolved),
            @"skipped_missing_id_name_mapping_names" : @(skippedUnnamed),
            @"deduplicated" : @(deduplicated),
            @"categories" : categoryCounts,
            @"identity" : @"top-level key = FBMobileConfigUserSessionContextManager external config stable ID; row key = parameterIndex",
        };
    }
    return document;
}

NSString *WAGRMobileConfigInternalPresetPolicyDescription(void) {
    return @"Resolver-driven preset: Employee/Internal Tester/Test User/Test Account, Dogfood/Fishfood, Private Experimentation, MobileConfig/Internal Debug, What's Broken, Internal Bug Reporting and Rage Shake. Negative-polarity disabled/kill/exclude gates are emitted false. Only BOOL mappings with UserSession external config ID + id_name_mapping config/parameter names are emitted.";
}
