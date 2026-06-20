// WAGramPrefix.h — Restored legacy kWAGR* constants for menu compatibility
// (after aggressive migration, some menu files still use old names)

#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#endif
#import "WAPrefix.h"
#import "WADefaults.h"
#import "Runtime/WAGateStore.h"
#import "Runtime/WAGateRegistry.h"

// === LEGACY kWAGR* constants (restored for WAGRMainSettingsVC.m and others) ===
#define kWAGRLiquidGlassMaster     @"wa_liquid_glass_method_hooks"
#define kWAGREmployeeMaster        @"watweak_bundle_internal_master"
#define kWAGRDogfoodGateInternalUser      @"watweak_gate_isInternalUser"
#define kWAGRDogfoodGateMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGRDogfoodGateMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGRDogfoodGateGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

#define kWAGRDebugMode         @"watweak_ui_debug_mode_enabled"
#define kWAGRInternalMaster    @"watweak_bundle_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_bundle_aura_simulation"

// New preferred WA names (use these going forward)
#define kWAGateEligibility      @"watweak_gate_eligibility_master"
#define kWAGateUsername         @"watweak_gate_username_master"
#define kWAGatePremiumBroadcast @"watweak_gate_premium_broadcast"

#define WAPref(key) WAPreferenceEnabled((key))

static inline BOOL WAPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    if (WAGateIsSet(key)) return WAGateGet(key);
    id defaultVal = WAGetDefault(key);
    if (defaultVal) {
        id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        if (stored) return [stored boolValue];
        if ([defaultVal isKindOfClass:NSNumber.class]) return [defaultVal boolValue];
        return NO;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

#define WAGRPref(key) WAPreferenceEnabled((key))

static inline NSString *WAGateKey(NSString *key) {
    return WAGateCanonicalKey(key ?: @"");
}

static inline BOOL WAGateIsOn(NSString *key) {
    if (!key.length) return NO;
    if (WAGateIsSet(key)) return WAGateGet(key);
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:WAGateCanonicalKey(key)];
    if ([stored respondsToSelector:@selector(boolValue)]) return [stored boolValue];
    return NO;
}

static inline NSString *WAGRKey(NSString *key) { return WAGateKey(key); }
static inline BOOL WAGRIsOn(NSString *key) { return WAGateIsOn(key); }
