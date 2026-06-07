#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRAuraEnsureHooksInstalled(void);
extern "C" NSString *WAGRAuraDiagnostic(void);
extern "C" NSString *WAGRAccountEligibilityDiagnostic(void);
extern "C" void WAGRWAABEnsureHooksInstalled(void);

extern "C" BOOL WAGRAuraSimulationEnabled(void) {
    return WAGRPref(kWAGRAuraSimulation) ||
           (WAGRGateIsSet(@"aura_subscription_simulation_enabled") && WAGRGateGet(@"aura_subscription_simulation_enabled"));
}

extern "C" BOOL WAGROpenSubscriptionsNative(void) {
    Class cls = NSClassFromString(@"WASubscriptionsNavigationController") ?: NSClassFromString(@"WASubscriptionsViewController");
    return cls != Nil;
}

extern "C" void WAGRAuraEnsureNavigationHooksInstalled(void) {
    WAGRAuraEnsureHooksInstalled();
    WAGRWAABEnsureHooksInstalled();
}

static void WAGRAuraSetSimulation(BOOL enabled) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (enabled) {
        [ud setBool:YES forKey:kWAGRAuraSimulation];
        WAGRGateSet(@"aura_subscription_simulation_enabled", YES);
        WAGRGateSet(@"aura_enabled", YES);
        WAGRGateSet(@"aura_settings_row_enabled", YES);
    } else {
        [ud removeObjectForKey:kWAGRAuraSimulation];
        WAGRGateClear(@"aura_subscription_simulation_enabled");
        WAGRGateClear(@"aura_enabled");
        WAGRGateClear(@"aura_settings_row_enabled");
    }
    [ud synchronize];
}

extern "C" void WAGRAuraActivateAllFlags(void) { WAGRAuraSetSimulation(YES); WAGRAuraEnsureNavigationHooksInstalled(); }
extern "C" void WAGRAuraDeactivateAllFlags(void) { WAGRAuraSetSimulation(NO); }

extern "C" BOOL WAGRPushAuraThemesVC(UIViewController *from) { (void)from; WAGRAuraActivateAllFlags(); return NO; }
extern "C" BOOL WAGRPushAuraIconsVC(UIViewController *from) { (void)from; WAGRAuraActivateAllFlags(); return NO; }
extern "C" BOOL WAGRPushAuraRingtonesVC(UIViewController *from) { (void)from; WAGRAuraActivateAllFlags(); return NO; }

extern "C" NSString *WAGRAuraNavigationDiagnostic(void) {
    NSString *aura = WAGRAuraDiagnostic();
    NSString *elig = WAGRAccountEligibilityDiagnostic();
    return [NSString stringWithFormat:@"Aura navigation compat owner=ON\nsimulation=%@\nopenSubscriptionsClass=%@\n\n%@\n\n%@",
            WAGRAuraSimulationEnabled() ? @"ON" : @"OFF",
            WAGROpenSubscriptionsNative() ? @"found" : @"missing",
            aura ?: @"Aura: n/a",
            elig ?: @"Eligibility: n/a"];
}
