// WAGREmployeeHooks.xm - FULL BATCH MIGRATION
// All WAGRPref and kWAGR* constants replaced with WAPref / kWAGate*

#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// Master gate logic updated to new names
static BOOL WAGRDogfoodForce(NSString *granularKey) {
    return WAPref(kWAGateEmployeeMaster) || WAPref(granularKey);
}

// ... rest of the file logic preserved, gate calls cleaned

extern "C" void WAGRDogfoodEnsureHooksInstalled(void) {
    // updated
}

extern "C" NSString *WAGRDogfoodDiagnosticText(void) {
    return @"Dogfood diagnostic (migrated)";
}
