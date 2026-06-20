// WAGramPrefix.h — unified prefix for WATweaks (WA prefix migration in progress)
// Aggressive WAGRGate* → WAGate* migration started (batch 1: Prefix + planning)

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
#import "Runtime/WAGRGateStore.h"     // will be migrated to WAGateStore.h soon
#import "Runtime/WAGRGateRegistry.h" // will be migrated to WAGateRegistry.h soon

#define kWAGRDebugMode         @"watweak_ui_debug_mode_enabled"
#define kWAGRInternalMaster    @"watweak_bundle_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_bundle_aura_simulation"

#define kWAGateEligibility      @"watweak_gate_eligibility_master"
#define kWAGateUsername         @"watweak_gate_username_master"
#define kWAGatePremiumBroadcast @"watweak_gate_premium_broadcast"

#define kWAGateDogfoodMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGateDogfoodMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGateDogfoodInternalUser      @"watweak_gate_isInternalUser"
#define kWAGateDogfoodGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

#define kWAGateLiquidGlassUserDefaults @"wa_liquid_glass_userdefaults_overrides"
#define kWAGateLiquidGlassMethodHooks  @"wa_liquid_glass_method_hooks"

#define WAPref(key) WAPreferenceEnabled((key))

static inline BOOL WAPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    if (WAGRGateIsSet(key)) return WAGRGateGet(key);
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
    return WAGRGateCanonicalKey(key ?: @"");
}

static inline BOOL WAGateIsOn(NSString *key) {
    if (!key.length) return NO;
    if (WAGRGateIsSet(key)) return WAGRGateGet(key);
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:WAGRGateCanonicalKey(key)];
    if ([stored respondsToSelector:@selector(boolValue)]) return [stored boolValue];
    return NO;
}

// Legacy aliases
static inline NSString *WAGRKey(NSString *key) { return WAGateKey(key); }
static inline BOOL WAGRIsOn(NSString *key) { return WAGateIsOn(key); }
