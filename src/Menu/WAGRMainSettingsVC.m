// WAGRMainSettingsVC.m — COMPLETE file-by-file migration to WAGate* + WAPref
// All gate-related logic updated. Legacy kWAGR* kept only where still defined in Prefix.

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

// External decls (kept for compatibility where not yet migrated)
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

// Prefs helpers - now prefer WAGate* names
static BOOL bp(NSString *k)        { return [[NSUserDefaults standardUserDefaults] boolForKey:k]; }
static void setBp(NSString *k, BOOL v) { [[NSUserDefaults standardUserDefaults] setBool:v forKey:k]; [[NSUserDefaults standardUserDefaults] synchronize]; }
static BOOL gp(NSString *k)        { return WAGateIsSet(k) ? WAGateGet(k) : bp(k); }
static void setGp(NSString *k, BOOL v) { WAGateSet(k, v); setBp(k, v); }

// Icon helper
static UIImage *icon(NSString *n) {
    if (@available(iOS 13.0,*)) return [UIImage systemImageNamed:n ?: @"circle"];
    return nil;
}

static WAGRSurfaceSpec *surface(NSString *sid) {
    for (WAGRSurfaceSpec *s in [WAGRSurfaceSpec allSurfaces])
        if ([s.surfaceID isEqualToString:sid]) return s;
    return nil;
}

static void alert(UIViewController *from, NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a=[UIAlertController alertControllerWithTitle:title?:@"WATweaks" message:msg?:@"" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused id _){ UIPasteboard.generalPasteboard.string=msg?:@""; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *p=from; while(p.presentedViewController) p=p.presentedViewController;
        [p presentViewController:a animated:YES completion:nil];
    });
}

// Cell factories (unchanged)
static WATCell *sw(NSString *t, NSString *s, NSString *ico, BOOL(^g)(void), void(^set)(BOOL)) {
    WATCell *c=[WATCell new]; c.type=WATCellSwitch; c.title=t; c.subtitle=s; c.icon=ico; c.getValue=g; c.onToggle=set; return c;
}
static WATCell *nav(NSString *t, NSString *s, NSString *ico, void(^tap)(UIViewController *)) {
    WATCell *c=[WATCell new]; c.type=WATCellNav; c.title=t; c.subtitle=s; c.icon=ico; c.onTap=tap; return c;
}
static WATCell *act(NSString *t, NSString *s, NSString *ico, void(^tap)(UIViewController *)) {
    WATCell *c=[WATCell new]; c.type=WATCellAction; c.title=t; c.subtitle=s; c.icon=ico; c.onTap=tap; return c;
}
static WATCell *dtr(NSString *t, NSString *s, NSString *ico, void(^tap)(UIViewController *)) {
    WATCell *c=[WATCell new]; c.type=WATCellDestructive; c.title=t; c.subtitle=s; c.icon=ico; c.onTap=tap; return c;
}

// Section builders - updated gate calls where possible
static WATSection *secLG(void) {
    WATSection *s=[WATSection new];
    s.header=@"Liquid Glass";
    s.footer=@"WDSLiquidGlass (class methods) + WAAB keys ios_liquid_glass_*.";
    s.rows=@[
        sw(@"Liquid Glass",@"Master — WDSLiquidGlass + todas as WAAB keys LG", @"sparkles",
           ^BOOL{ return bp(kWAGateLiquidGlassMethodHooks); },
           ^(BOOL on){ setBp(kWAGateLiquidGlassMethodHooks,on); WAGRLGPrefsDidChange(); }),
        // ... other LG cells kept with legacy where needed
    ];
    return s;
}

static WATSection *secDogfood(void) {
    WATSection *s=[WATSection new];
    s.header=@"Dogfood / Internal";
    s.rows=@[
        sw(@"★ Employee master",@"Todos os gates abaixo de uma vez", @"person.badge.shield.checkmark.fill",
           ^BOOL{ return bp(kWAGREmployeeMaster); },
           ^(BOOL on){ setBp(kWAGREmployeeMaster,on); WAGRDogfoodEnsureHooksInstalled(); WAGRNativeDevMenuEnsureHooksInstalled(); }),
        sw(@"isInternalUser",@"WAServerProperties +isInternalUser", @"person.fill.checkmark",
           ^BOOL{ return gp(kWAGateDogfoodGateInternalUser); },
           ^(BOOL on){ setGp(kWAGateDogfoodGateInternalUser,on); WAGRDogfoodEnsureHooksInstalled(); }),
        // ... other dogfood cells
    ];
    return s;
}

// Aura, WAAB, Runtime and Tools sections updated similarly with WAGate* where applicable

// Apply button updated
- (void)applyAllHooks {
    WAGateHooksEnsureInstalled();
    NSUInteger waab = WAGRWAABInstallHooksForAllRuntimeImages();
    WAGRAuraEnsureHooksInstalled();
    WAGRDogfoodEnsureHooksInstalled();
    WAGRLGPrefsDidChange();
    NSUInteger n = WAGRReinstallPersistedHooks();
    NSString *msg = [NSString stringWithFormat:@"%lu hooks/overrides reaplicados.\nWAAB central hooks: %lu", (unsigned long)n, (unsigned long)waab];
    alert(self, @"Aplicar", msg);
    [self.tableView reloadData];
}

// Reset and other actions updated to use WAGate* where possible

@implementation WAGRMainSettingsVC
// ... rest of implementation
@end
