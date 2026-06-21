// WAGramPrefix.h - FINAL CLEAN (Fase 0 completed)
// Only WAGate* + WAPref. Zero legacy kWAGR* constants or aliases.

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

#define kWAGateLiquidGlassMethodHooks   @"wa_liquid_glass_method_hooks"
#define kWAGateEmployeeMaster           @"watweak_bundle_internal_master"
#define kWAGateDogfoodGateInternalUser  @"watweak_gate_isInternalUser"
#define kWAGateDogfoodGateMetaEmployee  @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGateDebugMenuNative          @"watweak_gate_isDebugMenuAllowed"
#define kWAGateInternalMaster           @"watweak_bundle_internal_master"
#define kWAGateDebugMode                @"watweak_ui_debug_mode_enabled"
#define kWAGateAuraSimulation           @"watweak_bundle_aura_simulation"

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
