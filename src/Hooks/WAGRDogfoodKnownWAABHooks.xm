#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"

@interface WAABProperties : NSObject
- (BOOL)isMetaEmployeeOrInternalTester;
- (BOOL)is_meta_employee_or_internal_tester;
- (BOOL)is_internal_tester;
- (BOOL)waios_mc_debug_ui_enabled;
- (BOOL)whatsbroken_enabled;
- (BOOL)private_experimentation_should_sync;
- (BOOL)private_abprop_for_dev_only;
- (BOOL)private_experimentation_use_acs_config_id;
- (BOOL)dogfooding_nudge_settings_entrypoint_enabled;
- (BOOL)dogfooding_nudge_banner_home_screen_enabled;
- (BOOL)username_dogfooding_pn_privacy_enabled;
- (BOOL)username_dogfooding_pn_privacy_periodic_conversion_enabled;
- (BOOL)tbv_pass_eligibility_dogfooding_gk;
- (BOOL)get_help_internal_bug_report_enabled;
- (BOOL)give_dogfooders_task_id_for_bug_reporting;
- (BOOL)internal_bug_reporting_bottom_sheet;
- (BOOL)ios_internal_in_app_bug_reporting_enable;
- (BOOL)ios_internal_rage_shake_enabled;
- (BOOL)hn_dogfooding;
- (BOOL)malibu_dogfooding;
- (BOOL)graphQLEmployeeC1Disabled;
@end

static BOOL gWAGRKnownWAABDogfoodInstalled = NO;

static BOOL WAGRKnownDogfoodOverride(NSString *selectorName,
                                     BOOL masterValue,
                                     BOOL *outValue) {
    if (WAGRPref(kWAGREmployeeMaster)) {
        if (outValue) *outValue = masterValue;
        return YES;
    }
    if (selectorName.length && WAGRGateIsSet(selectorName)) {
        if (outValue) *outValue = WAGRGateGet(selectorName);
        return YES;
    }
    return NO;
}

%group WAGRKnownWAABDogfood

%hook WAABProperties

- (BOOL)isMetaEmployeeOrInternalTester {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"isMetaEmployeeOrInternalTester", YES, &value)) return value;
    return %orig;
}

- (BOOL)is_meta_employee_or_internal_tester {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"is_meta_employee_or_internal_tester", YES, &value)) return value;
    return %orig;
}

- (BOOL)is_internal_tester {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"is_internal_tester", YES, &value)) return value;
    return %orig;
}

- (BOOL)waios_mc_debug_ui_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"waios_mc_debug_ui_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)whatsbroken_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"whatsbroken_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)private_experimentation_should_sync {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"private_experimentation_should_sync", YES, &value)) return value;
    return %orig;
}

- (BOOL)private_abprop_for_dev_only {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"private_abprop_for_dev_only", YES, &value)) return value;
    return %orig;
}

- (BOOL)private_experimentation_use_acs_config_id {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"private_experimentation_use_acs_config_id", YES, &value)) return value;
    return %orig;
}

- (BOOL)dogfooding_nudge_settings_entrypoint_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"dogfooding_nudge_settings_entrypoint_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)dogfooding_nudge_banner_home_screen_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"dogfooding_nudge_banner_home_screen_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)username_dogfooding_pn_privacy_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"username_dogfooding_pn_privacy_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)username_dogfooding_pn_privacy_periodic_conversion_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"username_dogfooding_pn_privacy_periodic_conversion_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)tbv_pass_eligibility_dogfooding_gk {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"tbv_pass_eligibility_dogfooding_gk", YES, &value)) return value;
    return %orig;
}

- (BOOL)get_help_internal_bug_report_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"get_help_internal_bug_report_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)give_dogfooders_task_id_for_bug_reporting {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"give_dogfooders_task_id_for_bug_reporting", YES, &value)) return value;
    return %orig;
}

- (BOOL)internal_bug_reporting_bottom_sheet {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"internal_bug_reporting_bottom_sheet", YES, &value)) return value;
    return %orig;
}

- (BOOL)ios_internal_in_app_bug_reporting_enable {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"ios_internal_in_app_bug_reporting_enable", YES, &value)) return value;
    return %orig;
}

- (BOOL)ios_internal_rage_shake_enabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"ios_internal_rage_shake_enabled", YES, &value)) return value;
    return %orig;
}

- (BOOL)hn_dogfooding {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"hn_dogfooding", YES, &value)) return value;
    return %orig;
}

- (BOOL)malibu_dogfooding {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"malibu_dogfooding", YES, &value)) return value;
    return %orig;
}

- (BOOL)graphQLEmployeeC1Disabled {
    BOOL value = NO;
    if (WAGRKnownDogfoodOverride(@"graphQLEmployeeC1Disabled", NO, &value)) return value;
    return %orig;
}

%end
%end

extern "C" void WAGRDogfoodKnownWAABEnsureInstalled(void) {
    if (gWAGRKnownWAABDogfoodInstalled) return;
    Class cls = objc_getClass("WAABProperties");
    if (!cls) {
        NSLog(@"[WATweaks][Dogfood] WAABProperties is not loaded");
        return;
    }
    %init(WAGRKnownWAABDogfood);
    gWAGRKnownWAABDogfoodInstalled = YES;
    NSLog(@"[WATweaks][Dogfood] installed deterministic Employee/Internal/Tester/Dogfood WAAB hooks");
}

extern "C" NSString *WAGRDogfoodKnownWAABDiagnosticText(void) {
    Class cls = objc_getClass("WAABProperties");
    return [NSString stringWithFormat:
        @"WAABProperties=%@\nknownWAABHooks=%@\npositiveSelectors=20\nnegativeSelectors=1",
        cls ? @"YES" : @"NO",
        gWAGRKnownWAABDogfoodInstalled ? @"YES" : @"NO"];
}

__attribute__((constructor))
static void WAGRDogfoodKnownWAABCtor(void) {
    @autoreleasepool {
        if (!WAGRPref(kWAGREmployeeMaster)) return;
        WAGRDogfoodKnownWAABEnsureInstalled();
    }
}
