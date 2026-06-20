// WADefaults.m
// Following RyukGramPriv / AGENTS.md baseline for WATweaks (WA prefix)

#import "WADefaults.h"
#import <Foundation/Foundation.h>

static NSDictionary<NSString *, id> *gWADefaults = nil;
static dispatch_once_t gWADefaultsOnce;

NSDictionary<NSString *, id> * WADefaultsDictionary(void) {
    dispatch_once(&gWADefaultsOnce, ^{
        gWADefaults = @{
            // Gate / override system (core persisted feature)
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

            // Liquid Glass
            @"wa_liquid_glass_userdefaults_overrides" : @NO,
            @"wa_liquid_glass_method_hooks" : @NO,

            // Add new keys here when introducing features.
            // Every key here is automatically included in backup/export.
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
