#import "WAGRMobileConfigSemanticPreset.h"
#import "WAGRABPropsCanonicalNamesV2.h"

static NSString * const kWAGRMCInternalPresetErrorDomain = @"WATweaks.MobileConfig.InternalPreset";

static NSSet<NSNumber *> *WAGRMCInternalPresetExplicitIDs(void) {
    static NSSet<NSNumber *> *ids = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // IDs below were decoded from the current iOS WhatsApp/SharedModules AB
        // getter descriptors during this investigation. Dynamic semantic matching
        // below augments the list for new build-specific related gates.
        ids = [NSSet setWithArray:@[
            @1664,@1777,@2298,@2945,@3321,@6415,@8992,@9660,@9752,
            @13556,@14389,@15228,@15548,@17221,@17224,@18109,@18268,
            @18302,@18303,@18597,@18954,@19675,@19685,@19892,@20887,
            @21000,@21126,@21994,@22336,@22363,@22652,@22692,@22822,
            @22843,@23203,@23336,@23978,@24161,@24285,@24421,@24422,
            @24738,@24740,@24850,@24907,@25057,@25122,@25185,@25419,
            @26307,@26311,@26560,@26860,@27444,@27964,@29312,@29458,
            @29948,@33088,@33156,@33561,@34577
        ]];
    });
    return ids;
}

static BOOL WAGRMCInternalPresetPlatformExcluded(NSString *lowerName) {
    if (!lowerName.length) return NO;
    return [lowerName hasPrefix:@"web_"] ||
           [lowerName hasPrefix:@"wa_web_"] ||
           [lowerName hasPrefix:@"macos_"] ||
           [lowerName hasPrefix:@"android_"] ||
           [lowerName hasPrefix:@"windows_"];
}

static NSString *WAGRMCInternalPresetSemanticReason(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    if (!lower.length || WAGRMCInternalPresetPlatformExcluded(lower)) return nil;

    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"employee", @"employee/internal"],
        @[@"internal", @"employee/internal"],
        @[@"tester", @"test/internal"],
        @[@"test_user", @"test user"],
        @[@"test_account", @"test account"],
        @[@"dogfood", @"dogfood"],
        @[@"fishfood", @"fishfood"],
        @[@"rage_shake", @"rage shake"],
        @[@"rageshake", @"rage shake"],
        @[@"bug_report", @"bug reporting"],
        @[@"bugreport", @"bug reporting"],
        @[@"whatsbroken", @"debug/internal tools"],
        @[@"debug_ui", @"debug UI"],
        @[@"debug_menu", @"debug menu"],
        @[@"testflight", @"testflight/internal"],
        @[@"private_abprop", @"private experimentation"],
        @[@"private_experiment", @"private experimentation"],
        @[@"internal_tool", @"internal tools"],
        @[@"developer", @"developer/internal"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        if ([lower containsString:rule[0]]) return rule[1];
    }
    return nil;
}

static NSString *WAGRMCInternalPresetISO8601Now(void) {
    if (@available(iOS 10.0, *)) {
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        return [formatter stringFromDate:[NSDate date]] ?: @"";
    }
    return [[NSDate date] description];
}

static NSComparisonResult WAGRMCInternalPresetRowCompare(NSString *left, NSString *right) {
    NSInteger a = [[[left componentsSeparatedByString:@":"] firstObject] integerValue];
    NSInteger b = [[[right componentsSeparatedByString:@":"] firstObject] integerValue];
    if (a < b) return NSOrderedAscending;
    if (a > b) return NSOrderedDescending;
    return [left compare:right];
}

NSDictionary<NSString *, NSArray<NSString *> *> *
WAGRMobileConfigInternalPresetDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id userContext,
    NSDictionary<NSString *, id> **validationReport,
    NSError **outError) {

    id manager = WAGRMobileConfigContextManager(userContext);
    NSString *managerClass = manager ? NSStringFromClass([manager class]) : @"";
    if (!manager || [managerClass rangeOfString:@"UserSessionContextManager"
                                         options:NSCaseInsensitiveSearch].location == NSNotFound) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWAGRMCInternalPresetErrorDomain code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    @"O preset só é gerado com FBMobileConfigUserSessionContextManager vivo. Sessionless/defaultValue não é aceito para fabricar mc_overrides."}];
        }
        return nil;
    }
    if (!mappings.count) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWAGRMCInternalPresetErrorDomain code:2
                userInfo:@{NSLocalizedDescriptionKey:@"Execute primeiro o scan AB → MobileConfig."}];
        }
        return nil;
    }

    NSSet<NSNumber *> *explicitIDs = WAGRMCInternalPresetExplicitIDs();
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *wire = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *selected = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *unresolved = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *mismatches = [NSMutableArray array];
    NSMutableSet<NSString *> *seenParamUIDs = [NSMutableSet set];

    NSUInteger translated = 0;
    NSUInteger externalResolved = 0;
    NSUInteger externalEqualsWA = 0;
    NSUInteger skippedNonBool = 0;
    NSUInteger deduplicated = 0;
    NSUInteger semanticDynamic = 0;
    NSUInteger explicitSelected = 0;

    for (WAGRMobileConfigMapping *mapping in mappings) {
        if (!mapping.paramSpecifier) continue;
        translated++;
        if (mapping.externalConfigStableId) externalResolved++;
        if (mapping.externalConfigStableId && mapping.externalConfigStableId == mapping.waStableId) externalEqualsWA++;

        NSString *code = [NSString stringWithFormat:@"%lu", (unsigned long)mapping.waStableId];
        NSString *canonical = WAGRABPropsCanonicalNameForCode(code) ?: @"";
        NSString *reason = WAGRMCInternalPresetSemanticReason(canonical);
        BOOL explicitlySelected = [explicitIDs containsObject:@(mapping.waStableId)];
        if (!explicitlySelected && !reason.length) continue;
        if (explicitlySelected) explicitSelected++;
        else semanticDynamic++;

        if (mapping.nativeType != 1) {
            skippedNonBool++;
            continue;
        }

        NSMutableDictionary *entry = [@{
            @"wa_stable_id": @(mapping.waStableId),
            @"name": canonical.length ? canonical : @"(name unavailable)",
            @"selection": explicitlySelected ? @"explicit binary-validated core" : (reason ?: @"semantic"),
            @"param_specifier_hex": [NSString stringWithFormat:@"0x%016llx", mapping.paramSpecifier],
            @"local_config_index": @(mapping.localConfigIndex),
            @"parameter_index": @(mapping.parameterIndex),
            @"compact_parameter_token": @(mapping.parameterStableId),
            @"external_config_stable_id": @(mapping.externalConfigStableId),
            @"external_equals_wa_stable_id": @(mapping.externalConfigStableId != 0 &&
                                                 mapping.externalConfigStableId == mapping.waStableId),
            @"native_type": @"bool",
            @"override_value": @YES
        } mutableCopy];
        if (mapping.configName.length) entry[@"config_name"] = mapping.configName;
        if (mapping.parameterName.length) entry[@"parameter_name"] = mapping.parameterName;

        if (!mapping.externalConfigStableId) {
            [unresolved addObject:entry];
            continue;
        }
        if (mapping.externalConfigStableId != mapping.waStableId) {
            [mismatches addObject:entry];
        }

        NSString *uid = [NSString stringWithFormat:@"%llu:%u",
                         mapping.externalConfigStableId, mapping.parameterIndex];
        if ([seenParamUIDs containsObject:uid]) {
            deduplicated++;
            continue;
        }
        [seenParamUIDs addObject:uid];

        // Exact grammar of the physical example. Human-readable names stay in
        // the sidecar validation report and never alter the parser-facing key.
        NSString *key = [NSString stringWithFormat:@"%llu:", mapping.externalConfigStableId];
        NSString *row = [NSString stringWithFormat:@"%u: : true", mapping.parameterIndex];
        NSMutableArray<NSString *> *rows = wire[key];
        if (!rows) {
            rows = [NSMutableArray array];
            wire[key] = rows;
        }
        [rows addObject:row];
        [selected addObject:entry];
    }

    [wire enumerateKeysAndObjectsUsingBlock:^(__unused NSString *key,
                                               NSMutableArray<NSString *> *rows,
                                               __unused BOOL *stop) {
        [rows sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return WAGRMCInternalPresetRowCompare(a, b);
        }];
    }];

    // Round-trip the finished object through NSJSONSerialization. This validates
    // JSON syntax/shape locally; native reader acceptance remains a separate
    // runtime/device test and is stated as such in the report.
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:wire
                                                       options:NSJSONWritingSortedKeys
                                                         error:&jsonError];
    id roundTrip = jsonData.length
        ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError] : nil;
    BOOL jsonRoundTripOK = !jsonError && [roundTrip isKindOfClass:NSDictionary.class] &&
                           [(NSDictionary *)roundTrip isEqualToDictionary:wire];
    if (!jsonRoundTripOK) {
        if (outError) {
            *outError = jsonError ?: [NSError errorWithDomain:kWAGRMCInternalPresetErrorDomain code:3
                userInfo:@{NSLocalizedDescriptionKey:@"O documento não passou no round-trip JSON local."}];
        }
        return nil;
    }

    if (validationReport) {
        *validationReport = @{
            @"format": @"WATweaks UserSession-validated semantic mc_overrides preset report",
            @"generated_at": WAGRMCInternalPresetISO8601Now(),
            @"manager_class": managerClass,
            @"paths": @{
                @"mc_overrides": WAGRMobileConfigOverridesPath(userContext) ?: NSNull.null,
                @"id_name_mapping": WAGRMobileConfigNamesPath(userContext) ?: NSNull.null
            },
            @"wire_grammar": @{
                @"top_level_key": @"<external_config_stable_id>:",
                @"row": @"<parameter_index>: : <typed_value>",
                @"preset_value": @"true",
                @"names_in_wire": @NO
            },
            @"scan": @{
                @"translated": @(translated),
                @"external_ids_resolved": @(externalResolved),
                @"external_equals_wa_stable_id": @(externalEqualsWA),
                @"external_mismatch_count": @(mismatches.count),
                @"selected_emitted": @(selected.count),
                @"selected_explicit_core": @(explicitSelected),
                @"selected_dynamic_semantic": @(semanticDynamic),
                @"selected_unresolved": @(unresolved.count),
                @"skipped_non_bool": @(skippedNonBool),
                @"deduplicated": @(deduplicated),
                @"configs": @(wire.count),
                @"json_round_trip_ok": @(jsonRoundTripOK)
            },
            @"selected": selected,
            @"selected_unresolved": unresolved,
            @"external_id_mismatches": mismatches,
            @"important": @"The document uses only getStableIdFromParamSpecifier: results from the live UserSession manager. localConfigIndex and compact_parameter_token are diagnostic only. JSON round-trip validates grammar locally; it does not by itself prove native reader acceptance on device."
        };
    }
    return wire;
}
