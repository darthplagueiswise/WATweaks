// WAGRSettingsRowsNativeHooks.xm
//
// Injeta a linha "WATweaks" na WASettingsViewController do WhatsApp.
//
// ANÁLISE BINÁRIA (SharedModules):
//   Classe confirmada: WASettingsViewController (ObjC, SharedModules)
//   Padrão: UITableViewController subclass.
//
// ESTRATÉGIA:
//   Hookear -viewDidLoad para adicionar um "WATweaks" item no início da
//   lista de seções do settings, e hookear:
//     -tableView:numberOfRowsInSection:   (adicionar +1 na seção 0)
//     -tableView:cellForRowAtIndexPath:   (retornar a célula WATweaks)
//     -tableView:didSelectRowAtIndexPath: (abrir o menu)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Menu/WAGRMainSettingsVC.h"

static NSUInteger gInjectAttempts = 0;
static BOOL gRowInjected = NO;

static NSString *gWASettingsClassName = nil;
static NSString *gWASettingsState = @"not attempted";

// ── Inject row position (row 0 of section 0) ─────────────────────────────────
#define WAGR_INJECT_SECTION 0
#define WAGR_INJECT_ROW 0

typedef NSInteger (*IntegerTV_t)(id,SEL,UITableView*,NSInteger);
typedef UITableViewCell *(*CellTV_t)(id,SEL,UITableView*,NSIndexPath*);
typedef void (*VoidTV_t)(id,SEL,UITableView*,NSIndexPath*);

static IntegerTV_t orig_numberOfRows = NULL;
static CellTV_t    orig_cellForRow   = NULL;
static VoidTV_t    orig_didSelect    = NULL;

static BOOL isInjectedPath(NSIndexPath *ip) {
    return ip.section == WAGR_INJECT_SECTION && ip.row == WAGR_INJECT_ROW;
}
static NSIndexPath *shiftDown(NSIndexPath *ip) {
    if (ip.section != WAGR_INJECT_SECTION) return ip;
    return [NSIndexPath indexPathForRow:ip.row - 1 inSection:ip.section];
}

static NSInteger hook_numberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger orig = orig_numberOfRows ? orig_numberOfRows(self, _cmd, tv, section) : 0;
    if (section == WAGR_INJECT_SECTION) return orig + 1;
    return orig;
}

static UITableViewCell *hook_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (isInjectedPath(ip)) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WATweaksRow"];
        c.textLabel.text = @"WATweaks";
        c.detailTextLabel.text = @"Liquid Glass · Aura · Dogfood · WAAB";
        if (@available(iOS 13.0,*))
            c.imageView.image = [UIImage systemImageNamed:@"wrench.and.screwdriver.fill"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    return orig_cellForRow ? orig_cellForRow(self, _cmd, tv, shiftDown(ip)) : nil;
}

static void hook_didSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (isInjectedPath(ip)) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        UIViewController *vc = (UIViewController *)self;
        WAGRMainSettingsVC *menu = [[WAGRMainSettingsVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:menu];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        if (@available(iOS 15.0,*)) {
            nav.sheetPresentationController.prefersGrabberVisible = YES;
            nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        }
        UIViewController *p = vc;
        while (p.presentedViewController) p = p.presentedViewController;
        [p presentViewController:nav animated:YES completion:nil];
        return;
    }
    if (orig_didSelect) orig_didSelect(self, _cmd, tv, shiftDown(ip));
}

static void WAGRInstallSettingsRowHooks(Class cls) {
    if (!cls) return;
    SEL sRows   = @selector(tableView:numberOfRowsInSection:);
    SEL sCell   = @selector(tableView:cellForRowAtIndexPath:);
    SEL sSel    = @selector(tableView:didSelectRowAtIndexPath:);
    if (!class_getInstanceMethod(cls, sRows)) return;
    MSHookMessageEx(cls, sRows, (IMP)hook_numberOfRows, (IMP *)&orig_numberOfRows);
    MSHookMessageEx(cls, sCell, (IMP)hook_cellForRow,   (IMP *)&orig_cellForRow);
    MSHookMessageEx(cls, sSel,  (IMP)hook_didSelect,    (IMP *)&orig_didSelect);
    gRowInjected = (orig_numberOfRows != NULL);
    gWASettingsState = gRowInjected ? @"injected" : @"hook failed";
    NSLog(@"[WATweaks][SettingsRow] class=%@ injected=%@", NSStringFromClass(cls), gRowInjected?@"YES":@"NO");
}

static void WAGRFindAndHookSettingsVC(void) {
    gInjectAttempts++;
    NSArray<NSString *> *candidates = @[
        @"WASettingsViewController",
        @"WANewSettingsViewController",
        @"WASettingsTableViewController",
    ];
    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (!cls || !class_getInstanceMethod(cls, @selector(tableView:numberOfRowsInSection:))) continue;
        gWASettingsClassName = name;
        WAGRInstallSettingsRowHooks(cls);
        if (gRowInjected) return;
    }
}

// ── Public API ───────────────────────────────────────────────────────────────
extern "C" void WAGRSettingsRowsNativeEnsureHooksInstalled(void) {
    if (gRowInjected) return;
    WAGRFindAndHookSettingsVC();
}
extern "C" void WAGRSettingsRowsNativeInjectIfPossible(id vc) {
    if (!vc || gRowInjected) return;
    WAGRInstallSettingsRowHooks([vc class]);
}
extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) {
    return gRowInjected;
}
extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"injected=%@\\nclass=%@\\nattempts=%lu\\nstate=%@\\nnumberOfRows=%@\\ncellForRow=%@\\ndidSelect=%@",
        gRowInjected?@"YES":@"NO",
        gWASettingsClassName?:@"none",
        (unsigned long)gInjectAttempts,
        gWASettingsState,
        orig_numberOfRows?@"OK":@"nil",
        orig_cellForRow?@"OK":@"nil",
        orig_didSelect?@"OK":@"nil"];
}

__attribute__((constructor))
static void WAGRSettingsRowCtor(void) {
    @autoreleasepool {
        WAGRFindAndHookSettingsVC();
        double d[]={0.5,1.5,4.0};
        for(NSUInteger i=0;i<3;i++)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d[i]*NSEC_PER_SEC)),
                           dispatch_get_main_queue(),^{
                if(!gRowInjected) WAGRFindAndHookSettingsVC();
            });
    }
}
