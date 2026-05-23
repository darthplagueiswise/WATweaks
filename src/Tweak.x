// Tweak.x — entry point. Zero Logos hooks here.
// ─────────────────────────────────────────────────────────────────────────────
// What this file owns now (post-refactor):
//
//   • The long-press gesture recognizer attached to every UITableView, which
//     is the activation path for the WATweaks (formerly WAGram) menu when
//     the user presses-and-holds the Help / Developer / WATweaks cells in
//     Settings. This must stay here because the wagr_validate_sources.py
//     script enforces the presence of UILongPressGestureRecognizer, WAGRLP,
//     attachLP, isTrigger and WAGRPresent tokens in this file.
//
//   • The UITableView -didMoveToWindow swizzle, which is now only used to
//     attach the long-press recognizer. The visible WATweaks entry is installed by
//     WAGRSettingsRowsNativeHooks.xm as a safe settings bar button.
//
//   • Diagnostic and ensure-installed shim functions that delegate to the
//     dedicated hook files. Tweak.x is the orchestrator; specific hooks
//     live in src/Hooks/.
//
// Crash-history note: the previous viewDidAppear: swizzle on UIViewController
// caused recursive reentry into a global hook. That code path was removed in
// favor of the table-centric didMoveToWindow path you see below. Do not
// reintroduce a base-class viewDidAppear: hook here.
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Menu/WAGRSurfaceListVC.h"
#import "Menu/WAGRSecretMenusVC.h"
#import "WAGramPrefix.h"

// ── External entry points provided by dedicated hook files ──────────────────
extern NSUInteger WAGRReinstallPersistedHooks(void);
extern void       WAGRDogfoodEnsureHooksInstalled(void);
extern void       WAGRLGPrefsDidChange(void);
extern void       WAGRWAABEnsureHooksInstalled(void);
extern void       WAGRAuraEnsureHooksInstalled(void);
extern NSString  *WAGRHookRouterDiagnostic(void);

// Native developer menu surface — moved out of Tweak.x into a dedicated file.
extern void       WAGRNativeDevMenuEnsureHooksInstalled(void);
extern NSString  *WAGRNativeDevMenuDiagnosticText(void);

// Native WhatsApp Settings rows — implemented in WASettingsViewController's
// WATableSection/WATableRow pipeline.
extern void       WAGRSettingsRowsNativeEnsureHooksInstalled(void);
extern NSString  *WAGRSettingsRowsNativeDiagnosticText(void);
extern void       WAGRSettingsRowsNativeInjectIfPossible(id settingsVC);

// WAAccountEligibility surface — the real gate the Settings VC consults
// for the Subscriptions / WA Plus row, plus several other family-of-apps
// surface eligibilities. Lives in SharedModules; loaded slightly after the
// main image, so the bootstrap is delay-staggered like the WAAB observer.
extern void       WAGRAccountEligibilityEnsureHooksInstalled(void);
extern NSString  *WAGRAccountEligibilityDiagnostic(void);
extern void       WAGRContextMenuPipelineProbeEnsureInstalled(void);
extern NSString  *WAGRContextMenuPipelineProbeDiagnosticText(void);

// ── Long-press setup ─────────────────────────────────────────────────────────
// kLP is the associated-object key used to mark a UITableView as "long-press
// already attached", so we never double-attach when -didMoveToWindow fires
// repeatedly during the table's lifetime.
static const char *kLP = "wagr.lp.ok";
static const char *kWAGRGlobalDoubleTapKey = "wagr.global.doubletap.ok";

static void (*orig_tableDidMoveToWindow)(id, SEL) = NULL;
static void (*orig_windowDidMoveToWindow)(id, SEL) = NULL;
static BOOL gTableHooked = NO;
static BOOL gWindowHooked = NO;

// Master gate: any of these prefs being ON is enough to unlock all the
// "native developer menu" gating behavior throughout the tweak. The list is
// historical — older builds used different keys — and we OR them so users
// who already had any one of them set don't need to reconfigure.
static BOOL WAGRNativeDebugAllowed(void) {
    return WAGRPref(kWAGRDebugMenuNative) || WAGRPref(kWAGRInternalMaster) ||
           WAGRPref(kWAGREmployeeMaster)  || WAGRPref(kWAGRDebugMode);
}

// ── Modal presentation of the WATweaks menu ──────────────────────────────────
// Used by the long-press path. The native settings-row path has its own
// presenter in WAGRSettingsRowsNativeHooks.xm; both end up presenting the same
// WAGRSurfaceListVC.
static void WAGRPresent(UIViewController *from) {
    if (!from) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *p = from;
        while (p.presentedViewController) p = p.presentedViewController;

        WAGRSurfaceListVC *menu = [[WAGRSurfaceListVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:menu];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;

        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sh = nav.sheetPresentationController;
            sh.prefersGrabberVisible = YES;
            sh.detents = @[UISheetPresentationControllerDetent.largeDetent];
        }

        [p presentViewController:nav animated:YES completion:nil];
    });
}

// ── Long-press trigger detection ────────────────────────────────────────────
// We accept several cell texts as triggers: the user-facing "Ajuda" / "Help"
// or "Developer" cells, plus the new "WATweaks" cell. Lowercase comparison
// avoids locale surprises.
static NSString *cellText(UITableViewCell *c) {
    NSMutableArray *parts = [NSMutableArray array];

    void (^add)(id) = ^(id o) {
        if ([o isKindOfClass:NSString.class] && [o length]) {
            [parts addObject:[o lowercaseString]];
        }
    };

    add(c.reuseIdentifier);
    add(c.accessibilityIdentifier);
    add(c.accessibilityLabel);
    add(c.textLabel.text);
    add(c.detailTextLabel.text);

    return [parts componentsJoinedByString:@" "];
}

static BOOL isTrigger(UITableViewCell *c) {
    NSString *s = cellText(c);
    return [s containsString:@"help"] ||
           [s containsString:@"ajuda"] ||
           [s containsString:@"developer"] ||
           [s containsString:@"desenvolvedor"] ||
           [s containsString:@"watweaks"];
}

static UIViewController *vcForView(UIView *v) {
    UIResponder *r = v;
    while (r) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

static UIViewController *WAGRTopViewController(void) {
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            if (win.isKeyWindow && win.rootViewController) { root = win.rootViewController; break; }
        }
        if (root) break;
    }
    if (!root) root = UIApplication.sharedApplication.keyWindow.rootViewController;
    UIViewController *p = root;
    while (p.presentedViewController) p = p.presentedViewController;
    if ([p isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)p).visibleViewController ?: ((UINavigationController *)p).topViewController;
        if (top) p = top;
    } else if ([p isKindOfClass:UITabBarController.class]) {
        UIViewController *sel = ((UITabBarController *)p).selectedViewController;
        if ([sel isKindOfClass:UINavigationController.class]) sel = ((UINavigationController *)sel).visibleViewController ?: ((UINavigationController *)sel).topViewController;
        if (sel) p = sel;
    }
    return p;
}


static UIViewController *WAGRSettingsVCForTable(UITableView *tv) {
    UIViewController *vc = vcForView(tv);
    if (!vc) return nil;
    NSString *name = NSStringFromClass([vc class]);
    if ([name isEqualToString:@"WASettingsViewController"] ||
        [name containsString:@"WASettingsViewController"]) {
        return vc;
    }
    return nil;
}

// ── Long-press target object ────────────────────────────────────────────────
@interface WAGRLP : NSObject
+ (instancetype)shared;
- (void)lp:(UILongPressGestureRecognizer *)g;
@end

@implementation WAGRLP
+ (instancetype)shared {
    static WAGRLP *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [self new];
    });
    return s;
}

- (void)lp:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;

    UITableView *tv = (UITableView *)g.view;
    if (![tv isKindOfClass:UITableView.class]) return;

    NSIndexPath *ip = [tv indexPathForRowAtPoint:[g locationInView:tv]];
    if (!ip) return;

    UITableViewCell *c = [tv cellForRowAtIndexPath:ip];
    if (!isTrigger(c)) return;

    WAGRPresent(vcForView(tv));
}
@end

// ── Global fallback activation ────────────────────────────────────────────────
// Two-finger double tap on any WhatsApp window. This is intentionally attached
// to UIWindow instead of swizzling UIViewController lifecycle methods, avoiding
// the recursive launch crashes seen in older builds.
@interface WAGRGlobalTap : NSObject
+ (instancetype)shared;
- (void)tap:(UITapGestureRecognizer *)g;
@end

@implementation WAGRGlobalTap
+ (instancetype)shared {
    static WAGRGlobalTap *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}
- (void)tap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    WAGRPresent(WAGRTopViewController() ?: vcForView(g.view));
}
@end

static void attachGlobalOpenGestureToWindow(UIWindow *win) {
    if (!win || [objc_getAssociatedObject(win, kWAGRGlobalDoubleTapKey) boolValue]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[WAGRGlobalTap shared]
                                                                          action:@selector(tap:)];
    tap.numberOfTapsRequired = 2;
    tap.numberOfTouchesRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    objc_setAssociatedObject(win, kWAGRGlobalDoubleTapKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [win addGestureRecognizer:tap];
}

static void attachGlobalOpenGestureToExistingWindows(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) attachGlobalOpenGestureToWindow(win);
    }
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    if (key) attachGlobalOpenGestureToWindow(key);
}

// ── Long-press attachment ───────────────────────────────────────────────────
// 0.65s press duration matches the iOS system "long press" feel. We set
// cancelsTouchesInView to NO so normal taps on the cell still work.
static void attachLP(UITableView *tv) {
    if (!tv) return;
    if ([objc_getAssociatedObject(tv, kLP) boolValue]) return;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[WAGRLP shared]
                action:@selector(lp:)];

    lp.minimumPressDuration = 0.65;
    lp.cancelsTouchesInView = NO;

    objc_setAssociatedObject(tv, kLP, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tv addGestureRecognizer:lp];
}

// ── The single hook surface ──────────────────────────────────────────────────
// Every UITableView calls -didMoveToWindow when it lands on screen. We use
// that moment only to attach the long-press recognizer, which remains the
// fallback activation path if the settings bar button cannot be installed.
static void hookTableDidMoveToWindow(id self, SEL _cmd) {
    if (orig_tableDidMoveToWindow) orig_tableDidMoveToWindow(self, _cmd);

    if (![self isKindOfClass:UITableView.class]) return;
    UITableView *tv = (UITableView *)self;

    if (tv.window) {
        attachLP(tv);

        UIViewController *settingsVC = WAGRSettingsVCForTable(tv);
        if (settingsVC) {
            WAGRSettingsRowsNativeEnsureHooksInstalled();
    WAGRContextMenuPipelineProbeEnsureInstalled();
            WAGRSettingsRowsNativeInjectIfPossible(settingsVC);
        }
    }
}

static void hookWindowDidMoveToWindow(id self, SEL _cmd) {
    if (orig_windowDidMoveToWindow) orig_windowDidMoveToWindow(self, _cmd);
    if ([self isKindOfClass:UIWindow.class]) attachGlobalOpenGestureToWindow((UIWindow *)self);
}

static void installGlobalWindowTapHook(void) {
    if (gWindowHooked) { attachGlobalOpenGestureToExistingWindows(); return; }
    Class cls = UIWindow.class;
    SEL sel = @selector(didMoveToWindow);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { attachGlobalOpenGestureToExistingWindows(); return; }
    MSHookMessageEx(cls, sel, (IMP)hookWindowDidMoveToWindow, (IMP *)&orig_windowDidMoveToWindow);
    gWindowHooked = (orig_windowDidMoveToWindow != NULL);
    attachGlobalOpenGestureToExistingWindows();
}

static void installLongPressTableHook(void) {
    if (gTableHooked) return;

    Class cls = UITableView.class;
    SEL sel = @selector(didMoveToWindow);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    MSHookMessageEx(cls, sel, (IMP)hookTableDidMoveToWindow, (IMP *)&orig_tableDidMoveToWindow);
    gTableHooked = (orig_tableDidMoveToWindow != NULL);
}

// ── Diagnostic shim ──────────────────────────────────────────────────────────
// Tweak.x doesn't own any gating hooks anymore, so its diagnostic just
// summarizes the table-level state and forwards to the specialized files.
void WAGRDebugMenuEnsureHooksInstalled(void) {
    // Convenience: ensure both the dev-menu gates and the native settings row
    // hooks are in place. Each ensure-call is idempotent so this is safe to
    // call multiple times (e.g. when the menu is opened).
    installLongPressTableHook();
    installGlobalWindowTapHook();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRSettingsRowsNativeEnsureHooksInstalled();
    WAGRContextMenuPipelineProbeEnsureInstalled();
}


static void WAGRPresentSecretMenusFrom(UIViewController *host) {
    if (!host) return;
    WAGRSecretMenusVC *vc = [[WAGRSecretMenusVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.prefersGrabberVisible = YES;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
    }
    [host presentViewController:nav animated:YES completion:nil];
}

NSString *WAGRDebugMenuDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"nativeDebug=%@\ntableHook=%@\n\n[NativeDevMenu]\n%@\n\n[NativeSettingsRows]\n%@\n\n[ContextMenuPipeline]\n%@\n\n[Router]\n%@",
        WAGRNativeDebugAllowed() ? @"ON" : @"OFF",
        gTableHooked ? @"YES" : @"NO",
        gWindowHooked ? @"YES" : @"NO",
        WAGRNativeDevMenuDiagnosticText() ?: @"n/a",
        WAGRSettingsRowsNativeDiagnosticText() ?: @"n/a",
        WAGRContextMenuPipelineProbeDiagnosticText() ?: @"n/a",
        WAGRHookRouterDiagnostic() ?: @"n/a"];
}

// ── Startup ──────────────────────────────────────────────────────────────────
// Stays intentionally light. Heavy initializations live inside the dedicated
// hook files' own __attribute__((constructor)) blocks, which run after this
// %ctor in dyld order. The work here is the part Tweak.x specifically owns:
// the table hook, plus a delayed nudge so any late-loaded Swift classes get
// picked up.
static void startup(void) {
    @autoreleasepool {
        WAGRLGPrefsDidChange();
        installLongPressTableHook();
        installGlobalWindowTapHook();

        // Install idempotent runtime owners early. They return original behavior
        // until prefs/overrides are ON, but missing them during Settings build
        // causes Aura/LiquidGlass/Payments toggles to appear stale or no-op.
        WAGRWAABEnsureHooksInstalled();
        WAGRAuraEnsureHooksInstalled();
        WAGRNativeDevMenuEnsureHooksInstalled();
        WAGRSettingsRowsNativeEnsureHooksInstalled();
        WAGRAccountEligibilityEnsureHooksInstalled();

        if (WAGRPref(@"wagr.startupHooksEnabled")) {
            WAGRReinstallPersistedHooks();
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WAGRWAABEnsureHooksInstalled();
            WAGRAuraEnsureHooksInstalled();
            WAGRNativeDevMenuEnsureHooksInstalled();
            WAGRSettingsRowsNativeEnsureHooksInstalled();
            WAGRAccountEligibilityEnsureHooksInstalled();
            WAGRLGPrefsDidChange();
            if (WAGRPref(@"wagr.startupHooksEnabled")) WAGRReinstallPersistedHooks();
            if (WAGRNativeDebugAllowed()) WAGRDogfoodEnsureHooksInstalled();
        });
    }
}

%ctor {
    startup();
}
