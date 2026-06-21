// WAABPropsObserver.xm - Updated in Fase 1/2
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// Updated to delegate to WAGateHooks instead of old names.

extern "C" void WAGateHooksEnsureInstalled(void);

extern "C" void WAGRWAABEnsureHooksInstalled(void) {
    WAGateHooksEnsureInstalled();
}

// Other diagnostics updated where possible.
