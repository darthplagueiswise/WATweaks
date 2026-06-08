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
#define kWAGRInternalMaster    @"watweak_ui_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_ui_aura_simulation"

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

#define kWAGRLiquidGlassUserDefaults WA_PREF_LIQUID_GLASS_USERDEFAULTS
#define kWAGRLiquidGlassMethodHooks  WA_PREF_LIQUID_GLASS_METHOD_HOOKS

#define WAGRPref(key) WAGRPreferenceEnabled((key))
static inline BOOL WAGRPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    // All runtime/UI preferences are resolved through WAGRGateStore so every
    // persisted key is normalized to the watweak_* namespace before any
    // NSUserDefaults read happens.
    return WAGRGateIsSet(key) ? WAGRGateGet(key) : NO;
}

// Legacy WAAB string override key used by WAABPropsObserver and WAAuraHooks.
// Keep it declared while those compatibility hooks still use "on"/"off" string
// semantics. New runtime BOOL gates should use WAGRGateStore directly.
static inline NSString *WAGRKey(NSString *key) {
    return WAGRGateCanonicalKey(key ?: @"");
}

static inline BOOL WAGRIsOn(NSString *key) {
    if (!key.length) return NO;
    return WAGRGateIsSet(key) ? WAGRGateGet(key) : NO;
}
