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
- (BOOL)dogfooding_nudge_settings_entrypoint_enabled;
- (BOOL)dogfooding_nudge_banner_home_screen_enabled;
- (BOOL)get_help_internal_bug_report_enabled;
- (BOOL)give_dogfooders_task_id_for_bug_reporting;
- (BOOL)internal_bug_reporting_bottom_sheet;
- (BOOL)ios_internal_in_app_bug_reporting_enable;
- (BOOL)ios_internal_rage_shake_enabled;
- (BOOL)hn_dogfooding;
- (BOOL)malibu_dogfooding;
@end

static BOOL gWAGRKnownWAABDogfoodInstalled = NO;

static BOOL WAGRKnownDogfoodSelectorEnabled(NSString *selectorName) {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    return selectorName.length &&
           WAGRGateIsSet(selectorName) &&
           WAGRGateGet(selectorName);
}

%group WAGRKnownWAABDogfood

%hook WAABProperties

- (BOOL)isMetaEmployeeOrInternalTester {
    if (WAGRKnownDogfoodSelectorEnabled(@"isMetaEmployeeOrInternalTester")) return YES;
    return %orig;
}

- (BOOL)is_meta_employee_or_internal_tester {
    if (WAGRKnownDogfoodSelectorEnabled(@"is_meta_employee_or_internal_tester")) return YES;
    return %orig;
}

- (BOOL)is_internal_tester {
    if (WAGRKnownDogfoodSelectorEnabled(@"is_internal_tester")) return YES;
    return %orig;
}

- (BOOL)waios_mc_debug_ui_enabled {
    if (WAGRKnownDogfoodSelectorEnabled(@"waios_mc_debug_ui_enabled")) return YES;
    return %orig;
}

- (BOOL)whatsbroken_enabled {
    if (WAGRKnownDogfoodSelectorEnabled(@"whatsbroken_enabled")) return YES;
    return %orig;
}

- (BOOL)private_experimentation_should_sync {
    if (WAGRKnownDogfoodSelectorEnabled(@"private_experimentation_should_sync")) return YES;
    return %orig;
}

- (BOOL)private_abprop_for_dev_only {
    if (WAGRKnownDogfoodSelectorEnabled(@"private_abprop_for_dev_only")) return YES;
    return %orig;
}

- (BOOL)dogfooding_nudge_settings_entrypoint_enabled {
    if (WAGRKnownDogfoodSelectorEnabled(@"dogfooding_nudge_settings_entrypoint_enabled")) return YES;
    return %orig;
}

- (BOOL)dogfooding_nudge_banner_home_screen_enabled {
    if (WAGRKnownDogfoodSelectorEnabled(@"dogfooding_nudge_banner_home_screen_enabled")) return YES;
    return %orig;
}

- (BOOL)get_help_internal_bug_report_enabled {
    if (WAGRKnownDogfoodSelectorEnabled(@"get_help_internal_bug_report_enabled")) return YES;
    return %orig;
}

- (BOOL)give_dogfooders_task_id_for_bug_reporting {
    if (WAGRKnownDogfoodSelectorEnabled(@"give_dogfooders_task_id_for_bug_reporting")) return YES;
    return %orig;
}

- (BOOL)internal_bug_reporting_bottom_sheet {
    if (WAGRKnownDogfoodSelectorEnabled(@"internal_bug_reporting_bottom_sheet")) return YES;
    return %orig;
}

- (BOOL)ios_internal_in_app_bug_reporting_enable {
    if (WAGRKnownDogfoodSelectorEnabled(@"ios_internal_in_app_bug_reporting_enable")) return YES;
    return %orig;
}

- (BOOL)ios_internal_rage_shake_enabled {
    if (WAGRKnownDogfoodSelectorEnabled(@"ios_internal_rage_shake_enabled")) return YES;
    return %orig;
}

- (BOOL)hn_dogfooding {
    if (WAGRKnownDogfoodSelectorEnabled(@"hn_dogfooding")) return YES;
    return %orig;
}

- (BOOL)malibu_dogfooding {
    if (WAGRKnownDogfoodSelectorEnabled(@"malibu_dogfooding")) return YES;
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
    NSLog(@"[WATweaks][Dogfood] installed deterministic WAAB employee/dogfood hooks");
}

extern "C" NSString *WAGRDogfoodKnownWAABDiagnosticText(void) {
    Class cls = objc_getClass("WAABProperties");
    return [NSString stringWithFormat:@"WAABProperties=%@\nknownWAABHooks=%@",
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
