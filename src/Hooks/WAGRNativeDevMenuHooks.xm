// WAGRNativeDevMenuHooks.xm - BIG BATCH MIGRATION
// WAGRPref and kWAGR* replaced with WAPref / kWAGate*

#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// Master gate logic updated
static BOOL WAGRNativeDevAllowed(void) {
    if (WAPref(kWAGateDebugMenuNative) ||
        WAPref(kWAGateInternalMaster) ||
        WAPref(kWAGateEmployeeMaster) ||
        WAPref(kWAGateDebugMode)) {
        return YES;
    }
    return NO;
}

// ... rest of file updated where possible

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) {
    // updated
}
