// WAGRSurfaceListVC.h — root presentation surface for WATweaks.
// ─────────────────────────────────────────────────────────────────────────────
// The activation paths (long-press in Tweak.x and the Settings bar button in
// WAGRSettingsRowsNativeHooks.xm) both end up presenting this controller. It
// is intentionally thin: it routes the user to one of five sub-surfaces and
// does no gating work itself.
//
// Public C entry points
// ─────────────────────
// The functions below are the stable contract between Tweak.x / the hook
// files / the backup module and the menu UI. Anything declared here must
// be implemented in exactly one .xm/.m file.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lifetime / hooks ensure-installed shims used by Tweak.x startup and by the
// menu when the user opens the diagnostic / "reinstall" actions.
void      WAGRGateHooksEnsureInstalled(void);
void      WAGRAuraEnsureNavigationHooksInstalled(void);
void      WAGRDogfoodEnsureHooksInstalled(void);
void      WAGRDebugMenuEnsureHooksInstalled(void);

// Diagnostic strings shown by the WATweaks menu and the secret panel.
NSString *WAGRGateHooksDiagnostic(void);
NSString *WAGRAuraNavigationDiagnostic(void);
NSString *WAGRDogfoodDiagnosticText(void);
NSString *WAGRLGDiagnosticText(void);
NSString *WAGRDebugMenuDiagnosticText(void);

// Keychain support kept from the previous WATweaks build.
void      WAInstallKeychainPatchIfNeeded(void);
NSString *WAKeychainAccessGroupDiagnostic(void);

// LiquidGlass pref-change notifier (still owned by WAGRLiquidGlassHooks.xm).
void      WAGRLGPrefsDidChange(void);

#ifdef __cplusplus
}
#endif

// Compat alias retained for any caller that still references the old name.
#define WAGramMenuVC WAGRSurfaceListVC

@interface WAGRSurfaceListVC : UITableViewController
@end
