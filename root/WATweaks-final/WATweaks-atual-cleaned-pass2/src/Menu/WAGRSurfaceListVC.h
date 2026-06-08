// WAGRSurfaceListVC.h — root presentation surface for WATweaks.
// ─────────────────────────────────────────────────────────────────────────────
// The activation paths (long-press in Tweak.x and the Settings bar button in
// WAGRSettingsRowsNativeHooks.xm) both end up presenting this controller. It
// is intentionally thin: it routes the user to one of five sub-surfaces and
// does no gating work itself.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

void      WAGRGateHooksEnsureInstalled(void);
void      WAGRAuraEnsureNavigationHooksInstalled(void);
void      WAGRDogfoodEnsureHooksInstalled(void);
void      WAGRDebugMenuEnsureHooksInstalled(void);

NSString *WAGRGateHooksDiagnostic(void);
NSString *WAGRAuraNavigationDiagnostic(void);
NSString *WAGRDogfoodDiagnosticText(void);
NSString *WAGRLGDiagnosticText(void);
NSString *WAGRDebugMenuDiagnosticText(void);

void      WAInstallKeychainPatchIfNeeded(void);
NSString *WAKeychainAccessGroupDiagnostic(void);
void      WAGRLGPrefsDidChange(void);

// Compatibility shims retained because the Runtime Avançado-only menu still
// has diagnostic/reinstall rows with the old names. Implementations delegate
// to WAGRGateHooks and do not restore the removed duplicated UI paths.
void       WAGRWAABEnsureHooksInstalled(void);
NSUInteger WAGRReinstallPersistedHooks(void);
NSString  *WAGRHookRouterDiagnostic(void);

#ifdef __cplusplus
}
#endif

#define WAGramMenuVC WAGRSurfaceListVC

@interface WAGRSurfaceListVC : UITableViewController
@end
