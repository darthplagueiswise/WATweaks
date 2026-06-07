// Tweak.x — entry point.
//
// Startup rule: do not hook global UIKit surfaces during app launch. The
// Entry is long-press only. Do not inject a WATweaks row into WhatsApp Settings.
// The UITableView long-press hook is installed at startup with a Settings-only guard.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Menu/WAGRMainSettingsVC.h"
#import "WAGramPrefix.h"

extern NSString  *WAGRHookRouterDiagnostic(void);
extern void       WAGRNativeDevMenuEnsureHooksInstalled(void);
extern NSString  *WAGRNativeDevMenuDiagnosticText(void);
extern NSString  *WAGRSettingsRowsNativeDiagnosticText(void);

static const char *kLP = "wagr.lp.ok";

static void (*orig_tableDidMoveToWindow)(id, SEL) = NULL;
static BOOL gTableHooked = NO;

static BOOL WAGRNativeDebugAllowed(void) {
    return WAGRPref(kWAGRDebugMenuNative) || WAGRPref(kWAGRInternalMaster) ||
           WAGRPref(kWAGREmployeeMaster)  || WAGRPref(kWAGRDebugMode);
}

static void WAGRPresent(UIViewController *from) {
    if (!from) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *p = from;
        while (p.presentedViewController) p = p.presentedViewController;
        WAGRMainSettingsVC *menu = [[WAGRMainSettingsVC alloc] init];
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

static NSString *cellText(UITableViewCell *c) {
    NSMutableArray *parts = [NSMutableArray array];
    void (^add)(id) = ^(id o) {
        if ([o isKindOfClass:NSString.class] && [o length]) [parts addObject:[o lowercaseString]];
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

static UIViewController *WAGRSettingsVCForTable(UITableView *tv) {
    UIViewController *vc = vcForView(tv);
    if (!vc) return nil;
    NSString *name = NSStringFromClass([vc class]);
    if ([name isEqualToString:@"WASettingsViewController"] || [name containsString:@"WASettingsViewController"]) return vc;
    return nil;
}

@interface WAGRLP : NSObject
+ (instancetype)shared;
- (void)lp:(UILongPressGestureRecognizer *)g;
@end

@implementation WAGRLP
+ (instancetype)shared {
    static WAGRLP *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
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

static void attachLP(UITableView *tv) {
    if (!tv) return;
    if ([objc_getAssociatedObject(tv, kLP) boolValue]) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[WAGRLP shared] action:@selector(lp:)];
    lp.minimumPressDuration = 0.65;
    lp.cancelsTouchesInView = NO;
    objc_setAssociatedObject(tv, kLP, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tv addGestureRecognizer:lp];
}

static void hookTableDidMoveToWindow(id self, SEL _cmd) {
    if (orig_tableDidMoveToWindow) orig_tableDidMoveToWindow(self, _cmd);
    if (![self isKindOfClass:UITableView.class]) return;
    UITableView *tv = (UITableView *)self;
    if (!tv.window) return;

    // Critical performance guard: this is a global UITableView hook, so do
    // absolutely nothing unless the table belongs to WhatsApp Settings.
    UIViewController *settingsVC = WAGRSettingsVCForTable(tv);
    if (!settingsVC) return;

    attachLP(tv);

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

void WAGRDebugMenuEnsureHooksInstalled(void) {
    // Do not call this from startup. It is a manual/fallback ensure path.
    installLongPressTableHook();
    WAGRNativeDevMenuEnsureHooksInstalled();
}

NSString *WAGRDebugMenuDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"nativeDebug=%@\ntableHook=%@\n\n[NativeDevMenu]\n%@\n\n[NativeSettingsRows]\n%@\n\n[Router]\n%@",
        WAGRNativeDebugAllowed() ? @"ON" : @"OFF",
        gTableHooked ? @"YES" : @"NO",
        WAGRNativeDevMenuDiagnosticText() ?: @"n/a",
        WAGRSettingsRowsNativeDiagnosticText() ?: @"n/a",
        WAGRHookRouterDiagnostic() ?: @"n/a"];
}

static void startup(void) {
    @autoreleasepool {
        // Long-press entrypoint only. No native Settings row injection.
        installLongPressTableHook();
    }
}

%ctor {
    startup();
}
