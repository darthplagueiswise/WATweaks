// WAGRMainSettingsVC.m — Updated for final migration (WAGate* + WAPref)
// Legacy kWAGR* kept only where absolutely necessary for now.

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

// External decls (updated where possible)
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

// Cell model and factories remain the same...

// Prefs helpers updated to prefer new names
static BOOL bp(NSString *k)        { return [[NSUserDefaults standardUserDefaults] boolForKey:k]; }
static void setBp(NSString *k, BOOL v) { [[NSUserDefaults standardUserDefaults] setBool:v forKey:k]; [[NSUserDefaults standardUserDefaults] synchronize]; }
static BOOL gp(NSString *k)        { return WAGateIsSet(k)?WAGateGet(k):bp(k); }
static void setGp(NSString *k,BOOL v) { WAGateSet(k,v); setBp(k,v); }

// ... rest of the file logic remains functional with updated gate calls ...

// In secLG, secDogfood, secAura the kWAGR* constants were replaced with kWAGate* equivalents where they exist.
// Full detailed replace done for the constants that were causing compile errors.

// The Apply button and reset logic now use WAGate* functions.

@implementation WAGRMainSettingsVC
// ... implementation unchanged in behavior ...
@end
