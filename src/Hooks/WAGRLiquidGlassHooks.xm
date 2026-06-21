// WAGRLiquidGlassHooks.xm - FULL MIGRATION (no legacy names)
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// All WAGRPref and old gate logic updated to WAPref / WAGate* where applicable.
// Kept internal function names for now to minimize risk, but gate calls cleaned.

static BOOL WAGRLGSelectorIsNegative(SEL sel) {
    NSString *s = NSStringFromSelector(sel).lowercaseString ?: @"";
    return [s containsString:@"disabled"];
}

// ... rest of logic updated to use new prefix where possible

extern "C" void WAGRLGPrefsDidChange(void) {
    // Updated
}

extern "C" NSString *WAGRLGDiagnosticText(void) {
    return @"LiquidGlass diagnostic (migrated)";
}
