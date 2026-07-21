// WAGREmployeeHooks.xm
// Deterministic owner for the unified Employee / Internal / Tester / Dogfood mode.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"

extern "C" void WAGRGateHooksEnsureInstalled(void);
extern "C" NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);
extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern "C" NSUInteger WAGREmployeeSweepEnsureInstalled(void);
extern "C" NSString *WAGREmployeeSweepDiagnosticText(void);
extern "C" void WAGRDogfoodKnownWAABEnsureInstalled(void);
extern "C" NSString *WAGRDogfoodKnownWAABDiagnosticText(void);
extern "C" void WAGRDebugBuildEnsureInstalled(void);
extern "C" NSString *WAGRDebugBuildDiagnosticText(void);
extern "C" NSUInteger WAGRInternalToolsSweepSetEnabled(BOOL enabled);
extern "C" NSString *WAGRInternalToolsSweepDiagnosticText(void);

@interface WAServerProperties : NSObject
+ (BOOL)isInternalUser;
@end

static BOOL gWAGRKnownEmployeeInstalled = NO;

static BOOL WAGRKnownEmployeeHookRequested(void) {
    return WAGRPref(kWAGREmployeeMaster) ||
           WAGRGateIsSet(@"isInternalUser");
}

%group WAGRKnownEmployee

%hook WAServerProperties

+ (BOOL)isInternalUser {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    if (WAGRGateIsSet(@"isInternalUser")) {
        return WAGRGateGet(@"isInternalUser");
    }
    return %orig;
}

%end
%end

static BOOL WAGRMethodIsZeroArgBOOL(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c';
}

static void WAGRInstallKnownEmployeeHook(void) {
    if (gWAGRKnownEmployeeInstalled) return;

    Class cls = objc_getClass("WAServerProperties");
    SEL selector = sel_registerName("isInternalUser");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!WAGRMethodIsZeroArgBOOL(method)) {
        NSLog(@"[WATweaks][Employee] WAServerProperties +isInternalUser unavailable or ABI changed");
        return;
    }

    %init(WAGRKnownEmployee);
    gWAGRKnownEmployeeInstalled = YES;
    NSLog(@"[WATweaks][Employee] installed WAServerProperties +isInternalUser");
}

static NSDictionary<NSString *, NSNumber *> *WAGRManagedDogfoodDesiredGates(void) {
    static NSDictionary<NSString *, NSNumber *> *gates = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gates = @{
            @"isDebugBuild" : @YES,
            @"isDebugMenuAllowed" : @YES,
            @"isDebugMenuShortcutEnabled" : @YES,
            @"isInternalUser" : @YES,
            @"isMetaEmployeeOrInternalTester" : @YES,
            @"is_meta_employee_or_internal_tester" : @YES,
            @"is_internal_tester" : @YES,
            @"waios_mc_debug_ui_enabled" : @YES,
            @"whatsbroken_enabled" : @YES,
            @"private_experimentation_should_sync" : @YES,
            @"private_abprop_for_dev_only" : @YES,
            @"private_experimentation_use_acs_config_id" : @YES,
            @"dogfooding_nudge_settings_entrypoint_enabled" : @YES,
            @"dogfooding_nudge_banner_home_screen_enabled" : @YES,
            @"username_dogfooding_pn_privacy_enabled" : @YES,
            @"username_dogfooding_pn_privacy_periodic_conversion_enabled" : @YES,
            @"tbv_pass_eligibility_dogfooding_gk" : @YES,
            @"get_help_internal_bug_report_enabled" : @YES,
            @"give_dogfooders_task_id_for_bug_reporting" : @YES,
            @"internal_bug_reporting_bottom_sheet" : @YES,
            @"ios_internal_in_app_bug_reporting_enable" : @YES,
            @"ios_internal_rage_shake_enabled" : @YES,
            @"hn_dogfooding" : @YES,
            @"malibu_dogfooding" : @YES,
            @"bug_reporting_settings_entrypoint_enabled" : @YES,
            @"groups_member_recommendations_debug_ui" : @YES,
            @"call_spring_animation_debug_menu_enabled" : @YES,
            @"ios_optic_in_calling_debug_indicator_enabled" : @YES,
            @"ios_optic_debug_indicator_enabled" : @YES,
            @"ios_debug_status_infra_convert_message_to_status" : @YES,
            @"status_testflight_media_debugger_ios" : @YES,
            @"additional_logging_for_ios_chat_transfer_debug" : @YES,
            @"debug_chat_transfer" : @YES,
            @"show_additional_debug_info_for_chat_transfer" : @YES,
            @"bug_reporting_tigon_debug_info_upload_enabled" : @YES,
            @"ai_rich_response_ur_debug_overlay_enabled" : @YES,
            @"sg_whatsapp_enable_reverse_qr_when_debug_mwa_installed" : @YES,
            @"ios_internal_hall_enabled" : @YES,
            @"ios_internal_always_show_message_edit" : @YES,
            @"macos_internal_bugnub_for_selected_prod_users_enabled" : @YES,
            @"internal_group_indicator" : @YES,
            @"md_internal_app_log" : @YES,
            @"ios_falco_elevated_internal_client_logging_enabled" : @YES,
            @"enable_syncd_debug_data_in_patch" : @YES,
            @"wa_asteria_tools_tab_entrypoint_enabled" : @YES,
            @"wa_meta_one_biz_tools_entry_point_enabled" : @YES,
            @"ios_evolution_chat_themes_tool" : @YES,
            @"ios_evolution_chat_themes_tool_advanced" : @YES,
            @"stella_filebus_enabled" : @YES,
            @"stella_tests_bypass_biometric" : @YES,
            @"metaai_share_inbox_snapshot_enabled" : @YES,
            @"sg_stella_warp_app_start_app" : @YES,
            @"wearables_llama4_optin_text_enabled" : @YES,
            @"sg_upsell_linking_without_deeplink_to_meta_ai" : @YES,
            @"ai_meta_ai_in_app_tab_main_gate_enabled" : @YES,
            @"ai_new_chat_surface_meta_ai_enabled" : @YES,
            @"ai_voice_meta_ai_info_entry_enabled" : @YES,
            @"meta_ai_mode_selector_enabled" : @YES,
            @"settings_meta_ai_app_top_position_enabled" : @YES,
            @"graphQLEmployeeC1Disabled" : @NO,
            @"bonsai_remove_meta_ai_shortcut_setting_switch" : @NO,
            @"ios_contact_suggestions_internal_tool_exclude_employees_enabled" : @NO,
        };
    });
    return gates;
}

static NSDictionary *WAGRManagedGateBackup(void) {
    id raw = [[NSUserDefaults standardUserDefaults]
        objectForKey:WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP];
    return [raw isKindOfClass:NSDictionary.class] ? raw : @{};
}

static void WAGRApplyManagedDogfoodGates(BOOL enabled) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary<NSString *, NSNumber *> *desired = WAGRManagedDogfoodDesiredGates();

    if (enabled) {
        NSMutableDictionary *backup = [WAGRManagedGateBackup() mutableCopy];
        if (!backup) backup = [NSMutableDictionary dictionary];

        for (NSString *key in desired) {
            if (backup[key]) continue;
            BOOL present = WAGRGateIsSet(key);
            backup[key] = @{
                @"present" : @(present),
                @"value" : @(present ? WAGRGateGet(key) : NO),
            };
        }
        [defaults setObject:backup forKey:WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP];

        [desired enumerateKeysAndObjectsUsingBlock:
            ^(NSString *key, NSNumber *value, BOOL *stop) {
                (void)stop;
                WAGRGateSet(key, value.boolValue);
            }];
        [defaults synchronize];
        return;
    }

    NSDictionary *backup = WAGRManagedGateBackup();
    [backup enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, NSDictionary *entry, BOOL *stop) {
            (void)stop;
            if (![entry isKindOfClass:NSDictionary.class]) return;
            if ([entry[@"present"] boolValue]) {
                WAGRGateSet(key, [entry[@"value"] boolValue]);
            } else {
                WAGRGateClear(key);
            }
        }];

    [defaults removeObjectForKey:WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP];
    [defaults synchronize];
}

extern "C" void WAGRDogfoodEnsureHooksInstalled(void) {
    BOOL masterEnabled = WAGRPref(kWAGREmployeeMaster);

    if (!masterEnabled) {
        WAGRInternalToolsSweepSetEnabled(NO);
        WAGRApplyManagedDogfoodGates(NO);
    } else {
        WAGRApplyManagedDogfoodGates(YES);
    }

    if (WAGRKnownEmployeeHookRequested()) {
        WAGRInstallKnownEmployeeHook();
    }

    if (masterEnabled) {
        WAGRDebugBuildEnsureInstalled();
        WAGRDogfoodKnownWAABEnsureInstalled();
        WAGRGateHooksEnsureInstalled();
        WAGRWAABInstallHooksForAllRuntimeImages();
        WAGRNativeDevMenuEnsureHooksInstalled();
        WAGRInternalToolsSweepSetEnabled(YES);
    }

    if (WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP)) {
        WAGREmployeeSweepEnsureInstalled();
    }
}

extern "C" NSString *WAGRDogfoodDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"master=%@\nknownClass=%@\nknownHook=%@\nmanagedDesiredGates=%lu\nmanagedBackup=%lu\n\n[Debug build object]\n%@\n\n[Known WAAB]\n%@\n\n[Internal/Debug/Dogfood live sweep]\n%@\n\n[Employee sweep]\n%@",
        WAGRPref(kWAGREmployeeMaster) ? @"ON" : @"OFF",
        objc_getClass("WAServerProperties") ? @"YES" : @"NO",
        gWAGRKnownEmployeeInstalled ? @"YES" : @"NO",
        (unsigned long)WAGRManagedDogfoodDesiredGates().count,
        (unsigned long)WAGRManagedGateBackup().count,
        WAGRDebugBuildDiagnosticText() ?: @"n/a",
        WAGRDogfoodKnownWAABDiagnosticText() ?: @"n/a",
        WAGRInternalToolsSweepDiagnosticText() ?: @"n/a",
        WAGREmployeeSweepDiagnosticText() ?: @"n/a"];
}

__attribute__((constructor))
static void WAGREmployeeHooksCtor(void) {
    @autoreleasepool {
        BOOL masterEnabled = WAGRPref(kWAGREmployeeMaster);

        // Cheap preferences and direct known-class hooks only. Never scan here.
        if (masterEnabled) {
            WAGRApplyManagedDogfoodGates(YES);
        } else if (WAGRManagedGateBackup().count) {
            WAGRApplyManagedDogfoodGates(NO);
        }

        if (!WAGRKnownEmployeeHookRequested()) return;
        WAGRInstallKnownEmployeeHook();
        if (masterEnabled) {
            WAGRDebugBuildEnsureInstalled();
            WAGRDogfoodKnownWAABEnsureInstalled();
            WAGRGateHooksEnsureInstalled();
            WAGRWAABInstallHooksForAllRuntimeImages();
            WAGRNativeDevMenuEnsureHooksInstalled();
        }
    }
}
