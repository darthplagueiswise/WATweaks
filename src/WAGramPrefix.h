// WAGramPrefix.h — unified prefix for WATweaks (transitioning to WA prefix per user request)
// Following RyukGramPriv / AGENTS.md baseline

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
#import "Runtime/WAGRGateStore.h"

// Legacy WAGR keys kept for compatibility during transition
#define kWAGRKeychain          WA_PREF_KEYCHAIN_REWRITE
#define kWAGRKeychainObserver  WA_PREF_KEYCHAIN_OBSERVER
#define kWAGREmployeeMaster    WA_PREF_EMPLOYEE_MASTER
#define kWAGRABPropsObserver   WA_PREF_AB_OBSERVER
#define kWAGRLiquidGlassMaster WA_PREF_LIQUID_GLASS

#define kWAGRDebugMode         @"watweak_ui_debug_mode_enabled"
#define kWAGRInternalMaster    @"watweak_bundle_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_bundle_aura_simulation"

#define kWAGRGateEligibility      @"watweak_gate_eligibility_master"
#define kWAGRGateUsername         @"watweak_gate_username_master"
#define kWAGRGatePremiumBroadcast @"watweak_gate_premium_broadcast"

#define kWAGRDogfoodGateMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGRDogfoodGateMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGRDogfoodGateInternalUser      @"watweak_gate_isInternalUser"
#define kWAGRDogfoodGateGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

#define kWAGRLiquidGlassUserDefaults @"wa_liquid_glass_userdefaults_overrides"
#define kWAGRLiquidGlassMethodHooks  @"wa_liquid_glass_method_hooks"

// New recommended WA prefix (start using this going forward)
#define WAPref(key) WAPreferenceEnabled((key))

static inline BOOL WAPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;

    // Gate overrides take precedence (persisted system)
    if (WAGRGateIsSet(key)) {
        return WAGRGateGet(key);
    }

    // Check if key is registered in WADefaults
    id defaultVal = WAGetDefault(key);
    if (defaultVal) {
        id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        if (stored) return [stored boolValue];
        if ([defaultVal isKindOfClass:NSNumber.class]) return [defaultVal boolValue];
        return NO;
    }

    // Fallback to plain NSUserDefaults
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

// Keep WAGRPref as alias during transition
#define WAGRPref(key) WAPreferenceEnabled((key))

static inline NSString *WAGRKey(NSString *key) {
    return WAGRGateCanonicalKey(key ?: @"");
}

static inline BOOL WAGRIsOn(NSString *key) {
    if (!key.length) return NO;
    if (WAGRGateIsSet(key)) return WAGRGateGet(key);
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:WAGRGateCanonicalKey(key)];
    if ([stored respondsToSelector:@selector(boolValue)]) return [stored boolValue];
    return NO;
}
