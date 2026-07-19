// WADefaults.m
// Registered preferences are the single source used by backup/export.

#import "WADefaults.h"
#import "WAPrefix.h"
#import <Foundation/Foundation.h>

static NSDictionary<NSString *, id> *gWADefaults = nil;
static dispatch_once_t gWADefaultsOnce;

NSDictionary<NSString *, id> * WADefaultsDictionary(void) {
    dispatch_once(&gWADefaultsOnce, ^{
        gWADefaults = @{
            // Employee / Dogfood / Internal
            WA_PREF_EMPLOYEE_MASTER : @NO,
            WA_PREF_EMPLOYEE_SWEEP : @NO,
            WA_PREF_EMPLOYEE_SWEEP_OVERRIDES : @{},
            WA_PREF_EMPLOYEE_MANAGED_GATE_BACKUP : @{},
            WA_PREF_FORCE_DEBUG_BUILD : @NO,

            // Gate / override system
            @"watweak_gate_eligibility_master" : @NO,
            @"watweak_gate_username_master" : @NO,
            @"watweak_gate_premium_broadcast" : @NO,
            @"watweak_gate_isMetaEmployeeOrInternalTester" : @NO,
            @"watweak_gate_is_meta_employee_or_internal_tester" : @NO,
            @"watweak_gate_isInternalUser" : @NO,
            @"watweak_gate_graphQLEmployeeC1Disabled" : @NO,

            // Debug / internal
            @"watweak_ui_debug_mode_enabled" : @NO,
            @"watweak_bundle_internal_master" : @NO,
            @"watweak_gate_isDebugMenuAllowed" : @NO,
            @"watweak_bundle_aura_simulation" : @NO,

            // Runtime observers / compatibility
            WA_PREF_AB_OBSERVER : @NO,
            WA_PREF_RUNTIME_VALUE_OVERRIDES : @{},
            WA_PREF_KEYCHAIN_REWRITE : @NO,
            WA_PREF_KEYCHAIN_OBSERVER : @NO,

            // Liquid Glass
            WA_PREF_LIQUID_GLASS : @NO,
            WA_PREF_LIQUID_GLASS_USERDEFAULTS : @NO,
            WA_PREF_LIQUID_GLASS_METHOD_HOOKS : @NO,
        };
    });
    return gWADefaults;
}

id WAGetDefault(NSString *key) {
    if (!key.length) return nil;
    id val = WADefaultsDictionary()[key];
    if (val) return val;
    return [[NSUserDefaults standardUserDefaults] objectForKey:key];
}
