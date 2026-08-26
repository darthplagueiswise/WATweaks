// WAGREmployeeSweep.xm
// Retired compatibility surface. Employee/Internal state is now expressed by
// exact semantic/WAAB overrides in GateStore -> RuntimeValueStore. A second
// class-wide sweep with its own persistence would make the UI/runtime disagree.

#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"

static void WAGREmployeeSweepClearLegacyState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:WA_PREF_EMPLOYEE_SWEEP];
    [defaults removeObjectForKey:WA_PREF_EMPLOYEE_SWEEP_OVERRIDES];
    [defaults synchronize];
}

extern "C" NSUInteger WAGREmployeeSweepInstallNow(void) {
    WAGREmployeeSweepClearLegacyState();
    return 0;
}

extern "C" NSUInteger WAGREmployeeSweepDisable(void) {
    WAGREmployeeSweepClearLegacyState();
    return 0;
}

extern "C" NSUInteger WAGREmployeeSweepSetEnabled(BOOL enabled) {
    (void)enabled;
    WAGREmployeeSweepClearLegacyState();
    return 0;
}

extern "C" NSUInteger WAGREmployeeSweepEnsureInstalled(void) {
    WAGREmployeeSweepClearLegacyState();
    return 0;
}

extern "C" NSString *WAGREmployeeSweepDiagnosticText(void) {
    return @"retired=YES\nparallelSweepState=NO\nowner=GateStore/RuntimeValueStore exact targets";
}

__attribute__((constructor))
static void WAGREmployeeSweepCtor(void) {
    @autoreleasepool { WAGREmployeeSweepClearLegacyState(); }
}
