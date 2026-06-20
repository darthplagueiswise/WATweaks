// WAGramPrefix.h — Final cleaned version (Port completo + aggressive migration done)
// Following AGENTS.md baseline + WA prefix

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

// Gate master toggles (WA prefix - final, no legacy WAGR aliases)
#define kWAGateEligibility      @"watweak_gate_eligibility_master"
#define kWAGateUsername         @"watweak_gate_username_master"
#define kWAGatePremiumBroadcast @"watweak_gate_premium_broadcast"

#define kWAGateDogfoodMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGateDogfoodMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGateDogfoodInternalUser      @"watweak_gate_isInternalUser"
#define kWAGateDogfoodGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

#define kWAGateLiquidGlassUserDefaults @"wa_liquid_glass_userdefaults_overrides"
#define kWAGateLiquidGlassMethodHooks  @"wa_liquid_glass_method_hooks"

// Primary and only prefix now
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
