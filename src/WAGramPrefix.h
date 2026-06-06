// WAGramPrefix.h — single unified prefix for WATweaks.
// ─────────────────────────────────────────────────────────────────────────────
// Shared constants and small compatibility helpers. Runtime gate overrides go
// through WAGRGateStore; legacy WAAB string overrides are kept only for the
// WAABPropsObserver compatibility path.
// ─────────────────────────────────────────────────────────────────────────────

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
#define kWAGRDebugMode         @"watweak_ui_debug_mode_enabled"
#define kWAGRInternalMaster    @"watweak_bundle_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_bundle_aura_simulation"

// ── Per-feature master toggles for WAGRGlobalGateStub.xm ──────────────────
// Each key maps to a BOOL in NSUserDefaults.
// When YES, the corresponding %hook returns the gate-open value for ALL BOOL
// methods of that class so partial enablement doesn't leave dependencies unmet.
#define kWAGRGateEligibility      @"watweak_gate_eligibility_master"
#define kWAGRGateUsername         @"watweak_gate_username_master"
#define kWAGRGatePremiumBroadcast @"watweak_gate_premium_broadcast"

#define kWAGRDogfoodGateMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGRDogfoodGateMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGRDogfoodGateInternalUser      @"watweak_gate_isInternalUser"
#define kWAGRDogfoodGateGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

#define kWAGRLiquidGlassUserDefaults @"wa_liquid_glass_userdefaults_overrides"
#define kWAGRLiquidGlassMethodHooks  @"wa_liquid_glass_method_hooks"

#define WAGRPref(key) WAGRPreferenceEnabled((key))
static inline BOOL WAGRPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    if ([key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"watweak_ui_"] ||
        [key hasPrefix:@"wagr.dogfood.gate."] || [key hasPrefix:@"wa_lg_ios_liquid_glass_"]) {
        return WAGRGateIsSet(key) ? WAGRGateGet(key) : NO;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

// Legacy WAAB string override key used by WAABPropsObserver and WAAuraHooks.
// Keep it declared while those compatibility hooks still use "on"/"off" string
// semantics. New runtime BOOL gates should use WAGRGateStore directly.
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
