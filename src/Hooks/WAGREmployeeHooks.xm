// WAGREmployeeHooks.xm
// Deterministic WhatsApp Employee / Internal owner.

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

@interface WAServerProperties : NSObject
+ (BOOL)isInternalUser;
@end

static BOOL gWAGRKnownEmployeeInstalled = NO;

static BOOL WAGRKnownEmployeeEnabled(void) {
    return WAGRPref(kWAGREmployeeMaster) ||
           WAGRPref(kWAGRDogfoodGateInternalUser);
}

%group WAGRKnownEmployee

%hook WAServerProperties

+ (BOOL)isInternalUser {
    if (WAGRKnownEmployeeEnabled()) return YES;
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

static NSArray<NSString *> *WAGRManagedDogfoodPositiveGates(void) {
    static NSArray<NSString *> *gates = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gates = @[
            @"isDebugMenuAllowed",
            @"isDebugMenuShortcutEnabled",
            @"isMetaEmployeeOrInternalTester",
            @"is_meta_employee_or_internal_tester",
            @"is_internal_tester",
            @"waios_mc_debug_ui_enabled",
            @"whatsbroken_enabled",
            @"private_experimentation_should_sync",
            @"private_abprop_for_dev_only",
            @"dogfooding_nudge_settings_entrypoint_enabled",
            @"dogfooding_nudge_banner_home_screen_enabled",
            @"get_help_internal_bug_report_enabled",
            @"give_dogfooders_task_id_for_bug_reporting",
            @"internal_bug_reporting_bottom_sheet",
            @"ios_internal_in_app_bug_reporting_enable",
            @"ios_internal_rage_shake_enabled",
            @"hn_dogfooding",
            @"malibu_dogfooding",
        ];
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

    if (enabled) {
        NSDictionary *existingBackup = WAGRManagedGateBackup();
        if (existingBackup.count == 0) {
            NSMutableDictionary *backup = [NSMutableDictionary dictionary];
            for (NSString *key in WAGRManagedDogfoodPositiveGates()) {
                BOOL present = WAGRGateIsSet(key);
                backup[key] = @{
                    @"present" : @(present),
                    @"value" : @(present ? WAGRGateGet(key) : NO),
                };
            }
            [defaults setObject:backup forKey:WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP];
        }

        for (NSString *key in WAGRManagedDogfoodPositiveGates()) {
            WAGRGateSet(key, YES);
        }
        [defaults synchronize];
        return;
    }

    NSDictionary *backup = WAGRManagedGateBackup();
    [backup enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
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

    if (WAGRKnownEmployeeEnabled()) {
        WAGRInstallKnownEmployeeHook();
    }

    WAGRApplyManagedDogfoodGates(masterEnabled);

    if (masterEnabled) {
        // Deterministic targets first: these are concrete BOOL getters attached
        // to WAABProperties in the executable/SharedModules categories.
        WAGRDogfoodKnownWAABEnsureInstalled();

        // Reader hooks remain useful for keys consumed through typed key APIs,
        // but Dogfood no longer depends on those readers being the active path.
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
            @"master=%@\nknownClass=%@\nknownHook=%@\nmanagedGates=%lu\nmanagedBackup=%lu\n\n[Known WAAB]\n%@\n\n[Employee sweep]\n%@",
            WAGRPref(kWAGREmployeeMaster) ? @"ON" : @"OFF",
            objc_getClass("WAServerProperties") ? @"YES" : @"NO",
            gWAGRKnownEmployeeInstalled ? @"YES" : @"NO",
            (unsigned long)WAGRManagedDogfoodPositiveGates().count,
            (unsigned long)WAGRManagedGateBackup().count,
            WAGRDogfoodKnownWAABDiagnosticText() ?: @"n/a",
            WAGREmployeeSweepDiagnosticText() ?: @"n/a"];
}

__attribute__((constructor))
static void WAGREmployeeHooksCtor(void) {
    @autoreleasepool {
        if (!WAGRKnownEmployeeEnabled()) return;
        WAGRInstallKnownEmployeeHook();
    }
}
