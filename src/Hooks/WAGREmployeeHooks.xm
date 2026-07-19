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
            @"graphQLEmployeeC1Disabled" : @NO,
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

    WAGRApplyManagedDogfoodGates(masterEnabled);

    if (WAGRKnownEmployeeHookRequested()) {
        WAGRInstallKnownEmployeeHook();
    }

    if (masterEnabled) {
        WAGRDebugBuildEnsureInstalled();
        WAGRDogfoodKnownWAABEnsureInstalled();
        WAGRGateHooksEnsureInstalled();
        WAGRWAABInstallHooksForAllRuntimeImages();
        WAGRNativeDevMenuEnsureHooksInstalled();
    }

    if (WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP)) {
        WAGREmployeeSweepEnsureInstalled();
    }
}

extern "C" NSString *WAGRDogfoodDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"master=%@\nknownClass=%@\nknownHook=%@\nmanagedDesiredGates=%lu\nmanagedBackup=%lu\n\n[Debug build object]\n%@\n\n[Known WAAB]\n%@\n\n[Employee sweep]\n%@",
        WAGRPref(kWAGREmployeeMaster) ? @"ON" : @"OFF",
        objc_getClass("WAServerProperties") ? @"YES" : @"NO",
        gWAGRKnownEmployeeInstalled ? @"YES" : @"NO",
        (unsigned long)WAGRManagedDogfoodDesiredGates().count,
        (unsigned long)WAGRManagedGateBackup().count,
        WAGRDebugBuildDiagnosticText() ?: @"n/a",
        WAGRDogfoodKnownWAABDiagnosticText() ?: @"n/a",
        WAGREmployeeSweepDiagnosticText() ?: @"n/a"];
}

__attribute__((constructor))
static void WAGREmployeeHooksCtor(void) {
    @autoreleasepool {
        if (!WAGRKnownEmployeeHookRequested()) return;
        WAGRInstallKnownEmployeeHook();
        if (WAGRPref(kWAGREmployeeMaster)) {
            WAGRDebugBuildEnsureInstalled();
        }
    }
}
