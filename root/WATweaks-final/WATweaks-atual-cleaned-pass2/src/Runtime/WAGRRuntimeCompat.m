// WAGRRuntimeCompat.m — compatibility shims for the Runtime Avançado-only UI.
// These symbols keep older menu rows/build contracts compiling without
// restoring the removed duplicated GatingCatalog / GatingAreaMenuVC surfaces.
// Do not define symbols that already have real owners in hook files.

#import <Foundation/Foundation.h>
#import "WAGRGateStore.h"

#ifdef __cplusplus
extern "C" {
#endif

void WAGRGateHooksEnsureInstalled(void);
NSString *WAGRGateHooksDiagnostic(void);

NSUInteger WAGRReinstallPersistedHooks(void) {
    WAGRGateHooksEnsureInstalled();
    return WAGRGateAllOverrides().count;
}

NSString *WAGRHookRouterDiagnostic(void) {
    return WAGRGateHooksDiagnostic();
}

#ifdef __cplusplus
}
#endif
