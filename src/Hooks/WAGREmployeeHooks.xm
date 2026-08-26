// WAGREmployeeHooks.xm
// Semantic orchestration for Employee / Internal / Tester / Dogfood.
// Persisted feature state is owned by WAGRGateStore -> RuntimeValueStore for
// WAABProperties. There is deliberately no second Employee master store here.

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

static NSArray<NSString *> *WAGRInternalActivationSelectors(void) {
    static NSArray *selectors = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selectors = @[
            @"isInternalUser",
            @"isMetaEmployeeOrInternalTester",
            @"is_meta_employee_or_internal_tester",
            @"is_internal_tester",
            @"waios_mc_debug_ui_enabled",
            @"whatsbroken_enabled",
            @"private_experimentation_should_sync",
            @"dogfooding_nudge_settings_entrypoint_enabled",
            @"dogfooding_nudge_banner_home_screen_enabled",
            @"ios_internal_in_app_bug_reporting_enable",
            @"ios_internal_rage_shake_enabled",
        ];
    });
    return selectors;
}

static BOOL WAGRInternalActivationRequested(void) {
    for (NSString *selector in WAGRInternalActivationSelectors()) {
        if (WAGRGateIsSet(selector) && WAGRGateGet(selector)) return YES;
    }
    return NO;
}

%group WAGRKnownEmployee
%hook WAServerProperties
+ (BOOL)isInternalUser {
    if (WAGRGateIsSet(@"isInternalUser")) return WAGRGateGet(@"isInternalUser");
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

extern "C" void WAGRDogfoodEnsureHooksInstalled(void) {
    BOOL active = WAGRInternalActivationRequested();
    BOOL sweepEnabled = WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP);

    // Sweeps are explicitly opt-in diagnostics; they no longer own or expand the
    // Employee master state. Exact gate overrides remain authoritative.
    WAGRInternalToolsSweepSetEnabled(sweepEnabled && active);
    if (sweepEnabled && active) (void)WAGREmployeeSweepEnsureInstalled();

    if (!active) return;
    WAGRInstallKnownEmployeeHook();
    WAGRDebugBuildEnsureInstalled();
    WAGRDogfoodKnownWAABEnsureInstalled();
    WAGRGateHooksEnsureInstalled();
    (void)WAGRWAABInstallHooksForAllRuntimeImages();
    WAGRNativeDevMenuEnsureHooksInstalled();
}

extern "C" NSString *WAGRDogfoodDiagnosticText(void) {
    NSMutableArray<NSString *> *activeSelectors = [NSMutableArray array];
    for (NSString *selector in WAGRInternalActivationSelectors()) {
        if (WAGRGateIsSet(selector) && WAGRGateGet(selector)) [activeSelectors addObject:selector];
    }
    return [NSString stringWithFormat:
        @"parallelMaster=NO\nmanagedBackup=NO\ncanonicalState=GateStore/RuntimeValueStore\nactive=%@\nknownClass=%@\nknownHook=%@\nsweepOptIn=%@\n\n[Debug build object]\n%@\n\n[Known WAAB]\n%@\n\n[Internal/Debug/Dogfood live sweep]\n%@\n\n[Employee sweep]\n%@",
        activeSelectors.count ? [activeSelectors componentsJoinedByString:@", "] : @"none",
        objc_getClass("WAServerProperties") ? @"YES" : @"NO",
        gWAGRKnownEmployeeInstalled ? @"YES" : @"NO",
        WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP) ? @"ON" : @"OFF",
        WAGRDebugBuildDiagnosticText() ?: @"n/a",
        WAGRDogfoodKnownWAABDiagnosticText() ?: @"n/a",
        WAGRInternalToolsSweepDiagnosticText() ?: @"n/a",
        WAGREmployeeSweepDiagnosticText() ?: @"n/a"];
}

__attribute__((constructor))
static void WAGREmployeeHooksCtor(void) {
    @autoreleasepool {
        // No master expansion and no object sweep at cold start. Install only the
        // exact semantic bridge when canonical persisted gates request it.
        if (WAGRInternalActivationRequested()) WAGRDogfoodEnsureHooksInstalled();
    }
}
