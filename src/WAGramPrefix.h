// WAGramPrefix.h — unified prefix for WATweaks (WA prefix migration in progress - aggressive mode)
// WAGRGate* → WAGate* migration started

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
#import "Runtime/WAGateStore.h"   // migrated
#import "Runtime/WAGateRegistry.h" // migrated

// Legacy WAGR keys kept only for very old compatibility (will be removed later)
#define kWAGRKeychain          WA_PREF_KEYCHAIN_REWRITE
#define kWAGRKeychainObserver  WA_PREF_KEYCHAIN_OBSERVER
#define kWAGREmployeeMaster    WA_PREF_EMPLOYEE_MASTER

#define kWAGRDebugMode         @"watweak_ui_debug_mode_enabled"
#define kWAGRInternalMaster    @"watweak_bundle_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_bundle_aura_simulation"

// Gate master toggles (migrated names)
#define kWAGateEligibility      @"watweak_gate_eligibility_master"
#define kWAGateUsername         @"watweak_gate_username_master"
#define kWAGatePremiumBroadcast @"watweak_gate_premium_broadcast"

#define kWAGateDogfoodMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGateDogfoodMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGateDogfoodInternalUser      @"watweak_gate_isInternalUser"
#define kWAGateDogfoodGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

#define kWAGateLiquidGlassUserDefaults @"wa_liquid_glass_userdefaults_overrides"
#define kWAGateLiquidGlassMethodHooks  @"wa_liquid_glass_method_hooks"

// New WA prefix (primary going forward)
#define WAPref(key) WAPreferenceEnabled((key))

static inline BOOL WAPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    if (WAGateIsSet(key)) return WAGateGet(key);   // migrated
    id defaultVal = WAGetDefault(key);
    if (defaultVal) {
        id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        if (stored) return [stored boolValue];
        if ([defaultVal isKindOfClass:NSNumber.class]) return [defaultVal boolValue];
        return NO;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

// WAGRPref kept as temporary alias during aggressive migration
#define WAGRPref(key) WAPreferenceEnabled((key))

static inline NSString *WAGateKey(NSString *key) {   // new preferred name
    return WAGateCanonicalKey(key ?: @"");
}

static inline BOOL WAGateIsOn(NSString *key) {
    if (!key.length) return NO;
    if (WAGateIsSet(key)) return WAGateGet(key);
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:WAGateCanonicalKey(key)];
    if ([stored respondsToSelector:@selector(boolValue)]) return [stored boolValue];
    return NO;
}

// Legacy WAGR versions (will be removed after full migration)
static inline NSString *WAGRKey(NSString *key) { return WAGateKey(key); }
static inline BOOL WAGRIsOn(NSString *key) { return WAGateIsOn(key); }
