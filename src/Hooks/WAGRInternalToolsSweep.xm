#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" BOOL WAGRGateInstallHookForSelector(NSString *className,
                                                NSString *selectorName,
                                                BOOL isClassMethod);

static NSArray<NSString *> *gWAGRInternalToolsLastMatches = nil;
static NSUInteger gWAGRInternalToolsLastInstalled = 0;

static NSSet<NSString *> *WAGRKnownInternalToolsSelectors(void) {
    static NSSet<NSString *> *selectors = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selectors = [NSSet setWithArray:@[
            @"additional_logging_for_ios_chat_transfer_debug",
            @"ai_meta_ai_in_app_tab_main_gate_enabled",
            @"ai_new_chat_surface_meta_ai_enabled",
            @"ai_rich_response_ur_debug_overlay_enabled",
            @"ai_voice_meta_ai_info_entry_enabled",
            @"bonsai_remove_meta_ai_shortcut_setting_switch",
            @"bug_reporting_settings_entrypoint_enabled",
            @"bug_reporting_tigon_debug_info_upload_enabled",
            @"call_spring_animation_debug_menu_enabled",
            @"debug_chat_transfer",
            @"dogfooding_nudge_banner_home_screen_enabled",
            @"dogfooding_nudge_settings_entrypoint_enabled",
            @"enable_syncd_debug_data_in_patch",
            @"get_help_internal_bug_report_enabled",
            @"give_dogfooders_task_id_for_bug_reporting",
            @"graphQLEmployeeC1Disabled",
            @"groups_member_recommendations_debug_ui",
            @"hn_dogfooding",
            @"internal_bug_reporting_bottom_sheet",
            @"internal_group_indicator",
            @"ios_contact_suggestions_internal_tool_exclude_employees_enabled",
            @"ios_debug_status_infra_convert_message_to_status",
            @"ios_evolution_chat_themes_tool",
            @"ios_evolution_chat_themes_tool_advanced",
            @"ios_falco_elevated_internal_client_logging_enabled",
            @"ios_internal_always_show_message_edit",
            @"ios_internal_hall_enabled",
            @"ios_internal_in_app_bug_reporting_enable",
            @"ios_internal_rage_shake_enabled",
            @"ios_optic_debug_indicator_enabled",
            @"ios_optic_in_calling_debug_indicator_enabled",
            @"isMetaEmployeeOrInternalTester",
            @"is_internal_tester",
            @"is_meta_employee_or_internal_tester",
            @"macos_internal_bugnub_for_selected_prod_users_enabled",
            @"malibu_dogfooding",
            @"md_internal_app_log",
            @"meta_ai_mode_selector_enabled",
            @"metaai_share_inbox_snapshot_enabled",
            @"private_abprop_for_dev_only",
            @"private_experimentation_should_sync",
            @"private_experimentation_use_acs_config_id",
            @"settings_meta_ai_app_top_position_enabled",
            @"sg_stella_warp_app_start_app",
            @"sg_upsell_linking_without_deeplink_to_meta_ai",
            @"sg_whatsapp_enable_reverse_qr_when_debug_mwa_installed",
            @"show_additional_debug_info_for_chat_transfer",
            @"status_testflight_media_debugger_ios",
            @"stella_filebus_enabled",
            @"stella_tests_bypass_biometric",
            @"tbv_pass_eligibility_dogfooding_gk",
            @"username_dogfooding_pn_privacy_enabled",
            @"username_dogfooding_pn_privacy_periodic_conversion_enabled",
            @"wa_asteria_tools_tab_entrypoint_enabled",
            @"wa_meta_one_biz_tools_entry_point_enabled",
            @"waios_mc_debug_ui_enabled",
            @"wearables_llama4_optin_text_enabled",
            @"whatsbroken_enabled"
        ]];
    });
    return selectors;
}

static NSDictionary *WAGRInternalToolsSweepBackup(void) {
    id value = [[NSUserDefaults standardUserDefaults]
        objectForKey:WA_PREF_INTERNAL_TOOLS_SWEEP_BACKUP];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static BOOL WAGRInternalToolsMethodIsZeroArgBool(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c';
}

static BOOL WAGRInternalToolsSelectorIsRelevant(NSString *selectorName) {
    NSString *name = selectorName.lowercaseString ?: @"";
    if (!name.length) return NO;

    if ([name containsString:@"tooltip"] || [name containsString:@"toolbar"]) {
        return NO;
    }
    if ([name containsString:@"writing_tools"] ||
        [name containsString:@"draw_tool"]) {
        return NO;
    }

    if ([name containsString:@"employee"] ||
        [name containsString:@"dogfood"] ||
        [name containsString:@"developer"] ||
        [name containsString:@"assistant"] ||
        [name containsString:@"stella"] ||
        [name containsString:@"private_experimentation"] ||
        [name containsString:@"whatsbroken"] ||
        [name containsString:@"bug_reporting"] ||
        [name containsString:@"rage_shake"]) {
        return YES;
    }

    if ([name containsString:@"debug"]) return YES;

    if ([name containsString:@"internal"]) {
        return [name containsString:@"tool"] ||
               [name containsString:@"bug"] ||
               [name containsString:@"log"] ||
               [name containsString:@"indicator"] ||
               [name containsString:@"entrypoint"] ||
               [name containsString:@"settings"] ||
               [name containsString:@"hall"] ||
               [name containsString:@"message_edit"] ||
               [name containsString:@"group_indicator"] ||
               [name containsString:@"selected_prod_users"] ||
               [name containsString:@"client_logging"] ||
               [name containsString:@"only"];
    }

    if ([name containsString:@"_tool"]) {
        return [name containsString:@"entrypoint"] ||
               [name containsString:@"asteria"] ||
               [name containsString:@"meta_one"] ||
               [name containsString:@"evolution"] ||
               [name containsString:@"debug"] ||
               [name containsString:@"internal"];
    }

    BOOL metaAI = [name containsString:@"meta_ai"] ||
                  [name containsString:@"metaai"];
    if (metaAI) {
        return [name containsString:@"debug"] ||
               [name containsString:@"tool"] ||
               [name containsString:@"settings"] ||
               [name containsString:@"entry"] ||
               [name containsString:@"mode_selector"] ||
               [name containsString:@"inbox_snapshot"] ||
               [name containsString:@"voice"];
    }
    return NO;
}

static BOOL WAGRInternalToolsDesiredValue(NSString *selectorName) {
    NSString *name = selectorName.lowercaseString ?: @"";
    if ([name containsString:@"disabled"] ||
        [name containsString:@"disable_"] ||
        [name containsString:@"_disable"] ||
        [name containsString:@"kill_switch"] ||
        [name containsString:@"killswitch"] ||
        [name containsString:@"lockout"] ||
        [name containsString:@"exclude_employees"] ||
        ([name containsString:@"remove_"] &&
         [name containsString:@"setting_switch"])) {
        return NO;
    }
    return YES;
}

static BOOL WAGRInternalToolsHookWasPersisted(NSString *selectorName) {
    for (NSDictionary *spec in WAGRGatePersistedHookSpecs()) {
        if (![spec[@"class"] isEqualToString:@"WAABProperties"]) continue;
        if ([spec[@"meta"] boolValue]) continue;
        if ([spec[@"selector"] isEqualToString:selectorName]) return YES;
    }
    return NO;
}

static NSUInteger WAGRInternalToolsRestoreSweep(void) {
    NSDictionary *backup = WAGRInternalToolsSweepBackup();
    if (!backup.count) return 0;

    __block NSUInteger restored = 0;
    [backup enumerateKeysAndObjectsUsingBlock:
        ^(NSString *selectorName, NSDictionary *entry, BOOL *stop) {
            (void)stop;
            if (![selectorName isKindOfClass:NSString.class] ||
                ![entry isKindOfClass:NSDictionary.class]) return;
            if ([entry[@"present"] boolValue]) {
                WAGRGateSet(selectorName, [entry[@"value"] boolValue]);
            } else {
                WAGRGateClear(selectorName);
            }
            if (![entry[@"hookPresent"] boolValue]) {
                WAGRGateForgetHook(@"WAABProperties", selectorName, NO);
            }
            restored++;
        }];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:WA_PREF_INTERNAL_TOOLS_SWEEP_BACKUP];
    [defaults synchronize];
    gWAGRInternalToolsLastMatches = @[];
    gWAGRInternalToolsLastInstalled = 0;
    return restored;
}

extern "C" NSUInteger WAGRInternalToolsSweepSetEnabled(BOOL enabled) {
    if (!enabled) return WAGRInternalToolsRestoreSweep();

    Class cls = objc_getClass("WAABProperties");
    if (!cls) {
        gWAGRInternalToolsLastMatches = @[];
        gWAGRInternalToolsLastInstalled = 0;
        NSLog(@"[WATweaks][InternalTools] WAABProperties not loaded");
        return 0;
    }

    NSMutableDictionary *backup =
        [WAGRInternalToolsSweepBackup() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableOrderedSet<NSString *> *matches = [NSMutableOrderedSet orderedSet];
    NSUInteger installed = 0;

    unsigned int methodCount = 0;
    Method *methodList = class_copyMethodList(cls, &methodCount);
    for (unsigned int index = 0; index < methodCount; index++) {
        Method method = methodList[index];
        if (!WAGRInternalToolsMethodIsZeroArgBool(method)) continue;

        NSString *selectorName = NSStringFromSelector(method_getName(method));
        if (!WAGRInternalToolsSelectorIsRelevant(selectorName)) continue;
        if ([WAGRKnownInternalToolsSelectors() containsObject:selectorName]) continue;

        if (!backup[selectorName]) {
            BOOL present = WAGRGateIsSet(selectorName);
            backup[selectorName] = @{
                @"present" : @(present),
                @"value" : @(present ? WAGRGateGet(selectorName) : NO),
                @"hookPresent" : @(WAGRInternalToolsHookWasPersisted(selectorName)),
            };
        }

        BOOL desired = WAGRInternalToolsDesiredValue(selectorName);
        WAGRGateSet(selectorName, desired);
        if (WAGRGateInstallHookForSelector(@"WAABProperties",
                                           selectorName,
                                           NO)) {
            installed++;
        }
        [matches addObject:selectorName];
    }
    free(methodList);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:backup forKey:WA_PREF_INTERNAL_TOOLS_SWEEP_BACKUP];
    [defaults synchronize];

    gWAGRInternalToolsLastMatches = matches.array ?: @[];
    gWAGRInternalToolsLastInstalled = installed;
    NSLog(@"[WATweaks][InternalTools] live WAAB sweep matched=%lu installed=%lu",
          (unsigned long)matches.count, (unsigned long)installed);
    return installed;
}

extern "C" NSString *WAGRInternalToolsSweepDiagnosticText(void) {
    NSArray<NSString *> *matches = gWAGRInternalToolsLastMatches ?: @[];
    NSString *sample = matches.count
        ? [[matches subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)40,
                                                        matches.count))]
            componentsJoinedByString:@"\n"]
        : @"none this session";
    return [NSString stringWithFormat:
        @"backup=%lu\nlastMatched=%lu\nlastInstalled=%lu\n%@",
        (unsigned long)WAGRInternalToolsSweepBackup().count,
        (unsigned long)matches.count,
        (unsigned long)gWAGRInternalToolsLastInstalled,
        sample];
}

__attribute__((constructor))
static void WAGRInternalToolsSweepCtor(void) {
    @autoreleasepool {
        // No scan during launch. Only clean stale sweep state when the master is off.
        if (WAGRPref(kWAGREmployeeMaster)) return;
        if (!WAGRInternalToolsSweepBackup().count) return;
        WAGRInternalToolsRestoreSweep();
    }
}
