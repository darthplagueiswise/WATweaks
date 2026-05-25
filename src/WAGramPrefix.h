// WAGramPrefix.h — shared WATweaks prefix.

#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#endif
#import "WAPrefix.h"
#import "Runtime/WAGRGateStore.h"

#define kWAGRKeychain          WA_PREF_KEYCHAIN_REWRITE
#define kWAGRKeychainObserver  WA_PREF_KEYCHAIN_OBSERVER
#define kWAGREmployeeMaster    WA_PREF_EMPLOYEE_MASTER
#define kWAGRABPropsObserver   WA_PREF_AB_OBSERVER
#define kWAGRLiquidGlassMaster WA_PREF_LIQUID_GLASS
#define kWAGRDebugMode         @"wagr_debug_mode_enabled"
#define kWAGRInternalMaster    @"wagr_internal_master_enabled"
#define kWAGRDebugMenuNative   @"wagr_native_debug_menu_enabled"
#define kWAGRAuraSimulation    @"wagr_aura_simulation_enabled"

#define kWAGRDogfoodGateMetaEmployee      @"wagr.dogfood.gate.isMetaEmployeeOrInternalTester"
#define kWAGRDogfoodGateMetaEmployeeSnake @"wagr.dogfood.gate.is_meta_employee_or_internal_tester"
#define kWAGRDogfoodGateInternalUser      @"wagr.dogfood.gate.isInternalUser"
#define kWAGRDogfoodGateGraphQLEmpC1      @"wagr.dogfood.gate.graphQLEmployeeC1Disabled"

#define kWAGRLiquidGlassUserDefaults @"watweak_liquid_glass_userdefaults_overrides"
#define kWAGRLiquidGlassMethodHooks  @"watweak_liquid_glass_method_hooks"

#define WAGRPref(key) WAGRPreferenceEnabled((key))
static inline BOOL WAGRPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    if ([key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"watweak_ui_"] ||
        [key hasPrefix:@"wagr.dogfood.gate."] || [key hasPrefix:@"wa_lg_"] ||
        [key isEqualToString:@"wagr_native_debug_menu_enabled"] ||
        [key isEqualToString:@"wagr_internal_master_enabled"]) {
        return WAGRGateIsSet(key) ? WAGRGateGet(key) : NO;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}
