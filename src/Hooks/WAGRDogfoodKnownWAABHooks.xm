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

static BOOL WAGRKnownPositiveDogfoodValue(NSString *selectorName,
                                          BOOL originalValue) {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    if (selectorName.length && WAGRGateIsSet(selectorName)) {
        return WAGRGateGet(selectorName);
    }
    return originalValue;
}

static BOOL WAGRKnownNegativeDogfoodValue(NSString *selectorName,
                                          BOOL originalValue) {
    if (WAGRPref(kWAGREmployeeMaster)) return NO;
    if (selectorName.length && WAGRGateIsSet(selectorName)) {
        return WAGRGateGet(selectorName);
    }
    return originalValue;
}

%group WAGRKnownWAABDogfood

%hook WAABProperties

- (BOOL)isMetaEmployeeOrInternalTester {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    if (WAGRGateIsSet(@"isMetaEmployeeOrInternalTester")) {
        return WAGRGateGet(@"isMetaEmployeeOrInternalTester");
    }
    return %orig;
}

- (BOOL)is_meta_employee_or_internal_tester {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    if (WAGRGateIsSet(@"is_meta_employee_or_internal_tester")) {
        return WAGRGateGet(@"is_meta_employee_or_internal_tester");
    }
    return %orig;
}

- (BOOL)is_internal_tester {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    if (WAGRGateIsSet(@"is_internal_tester")) {
        return WAGRGateGet(@"is_internal_tester");
    }
    return %orig;
}

- (BOOL)waios_mc_debug_ui_enabled {
    return WAGRKnownPositiveDogfoodValue(@"waios_mc_debug_ui_enabled", %orig);
}

- (BOOL)whatsbroken_enabled {
    return WAGRKnownPositiveDogfoodValue(@"whatsbroken_enabled", %orig);
}

- (BOOL)private_experimentation_should_sync {
    return WAGRKnownPositiveDogfoodValue(@"private_experimentation_should_sync", %orig);
}

- (BOOL)private_abprop_for_dev_only {
    return WAGRKnownPositiveDogfoodValue(@"private_abprop_for_dev_only", %orig);
}

- (BOOL)private_experimentation_use_acs_config_id {
    return WAGRKnownPositiveDogfoodValue(@"private_experimentation_use_acs_config_id", %orig);
}

- (BOOL)dogfooding_nudge_settings_entrypoint_enabled {
    return WAGRKnownPositiveDogfoodValue(@"dogfooding_nudge_settings_entrypoint_enabled", %orig);
}

- (BOOL)dogfooding_nudge_banner_home_screen_enabled {
    return WAGRKnownPositiveDogfoodValue(@"dogfooding_nudge_banner_home_screen_enabled", %orig);
}

- (BOOL)username_dogfooding_pn_privacy_enabled {
    return WAGRKnownPositiveDogfoodValue(@"username_dogfooding_pn_privacy_enabled", %orig);
}

- (BOOL)username_dogfooding_pn_privacy_periodic_conversion_enabled {
    return WAGRKnownPositiveDogfoodValue(@"username_dogfooding_pn_privacy_periodic_conversion_enabled", %orig);
}

- (BOOL)tbv_pass_eligibility_dogfooding_gk {
    return WAGRKnownPositiveDogfoodValue(@"tbv_pass_eligibility_dogfooding_gk", %orig);
}

- (BOOL)get_help_internal_bug_report_enabled {
    return WAGRKnownPositiveDogfoodValue(@"get_help_internal_bug_report_enabled", %orig);
}

- (BOOL)give_dogfooders_task_id_for_bug_reporting {
    return WAGRKnownPositiveDogfoodValue(@"give_dogfooders_task_id_for_bug_reporting", %orig);
}

- (BOOL)internal_bug_reporting_bottom_sheet {
    return WAGRKnownPositiveDogfoodValue(@"internal_bug_reporting_bottom_sheet", %orig);
}

- (BOOL)ios_internal_in_app_bug_reporting_enable {
    return WAGRKnownPositiveDogfoodValue(@"ios_internal_in_app_bug_reporting_enable", %orig);
}

- (BOOL)ios_internal_rage_shake_enabled {
    return WAGRKnownPositiveDogfoodValue(@"ios_internal_rage_shake_enabled", %orig);
}

- (BOOL)hn_dogfooding {
    return WAGRKnownPositiveDogfoodValue(@"hn_dogfooding", %orig);
}

- (BOOL)malibu_dogfooding {
    return WAGRKnownPositiveDogfoodValue(@"malibu_dogfooding", %orig);
}

- (BOOL)graphQLEmployeeC1Disabled {
    return WAGRKnownNegativeDogfoodValue(@"graphQLEmployeeC1Disabled", %orig);
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
