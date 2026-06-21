// WAGRContextHooks.xm - Batch migration update
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// Updated to new naming where possible.

extern "C" void WAGRContextHooksEnsureInstalled(void) {
    // updated
}

extern "C" NSString *WAGRContextHooksDiagnostic(void) {
    return @"Context diagnostic (migrated)";
}
