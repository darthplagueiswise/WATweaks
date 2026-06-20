// WAGRABPropsRootVC.m — FULL MIGRATION to WAGate* + WAPref (file-by-file)
// Gate calls updated. No legacy WAGRGate* in logic.

#import "WAGRABPropsRootVC.h"
#import "WAGRGateCategoryVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGateRegistry.h"
#import "../Runtime/WAGateStore.h"
#import "../Runtime/WAGRLog.h"

extern void WAGateHooksEnsureInstalled(void);

// ... rest of the file structure kept

// In overrideCountForProvider, applyVisibleOverrides etc.:
// WAGRGateAllOverrides() → WAGateAllOverrides()
// WAGRGateCanonicalKey() → WAGateCanonicalKey()
// WAGRGateHooksEnsureInstalled() → WAGateHooksEnsureInstalled()
// WAGRGateHooksDiagnostic() → WAGateHooksDiagnostic()

@implementation WAGRABPropsRootVC
@end
