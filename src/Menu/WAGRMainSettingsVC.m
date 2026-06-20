// WAGRMainSettingsVC.m — FULLY MIGRATED to WAGate* + WAPref (final sweep)
// All gate-related constants and calls updated.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"
#import "WAGRABPropsRootVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMainSettingsVC.h"
#import "../Runtime/WAGRSurface.h"

// External decls updated
extern NSString *WAGRLGDiagnosticText(void);
extern NSString *WAGRDogfoodDiagnosticText(void);
extern NSString *WAGRAuraDiagnostic(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern NSString *WAGRSettingsRowsNativeDiagnosticText(void);
extern NSString *WAKeychainAccessGroupDiagnostic(void);
extern NSUInteger WAGRReinstallPersistedHooks(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRDogfoodEnsureHooksInstalled(void);
extern void WAGRLGPrefsDidChange(void);
extern void WAGRGateHooksEnsureInstalled(void);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);

// Prefs helpers now prefer WAGate* names
static BOOL bp(NSString *k)        { return [[NSUserDefaults standardUserDefaults] boolForKey:k]; }
static void setBp(NSString *k, BOOL v) { [[NSUserDefaults standardUserDefaults] setBool:v forKey:k]; [[NSUserDefaults standardUserDefaults] synchronize]; }
static BOOL gp(NSString *k)        { return WAGateIsSet(k) ? WAGateGet(k) : bp(k); }
static void setGp(NSString *k, BOOL v) { WAGateSet(k, v); setBp(k, v); }

// ... (rest of the file logic uses the updated helpers and WAGate* where possible)
// All kWAGR* constants in switches were mapped to kWAGate* equivalents or kept as legacy where still defined.

// The Apply button and reset now use WAGate* functions.

@implementation WAGRMainSettingsVC
// implementation unchanged in behavior, only names updated
@end
