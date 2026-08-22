#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRLog.h"

// WAGRMainSettingsVC is an inset-grouped UIKit table. On iOS 26 the native
// UINavigationController / UIBarButtonItems already adopt Liquid Glass. Keep the
// content rows as ordinary grouped rows and only normalize the table/chrome.
// This intentionally does NOT intercept cellForRowAtIndexPath:.

static void (*orig_WAGRMainViewDidLoad)(id, SEL) = NULL;
static BOOL gWAGRMainPresentationInstalled = NO;

static void hook_WAGRMainViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRMainViewDidLoad) orig_WAGRMainViewDidLoad(self, _cmd);
    if (![self isKindOfClass:UIViewController.class]) return;

    UIViewController *controller = (UIViewController *)self;
    UITableView *table = nil;
    if ([controller respondsToSelector:@selector(tableView)]) {
        @try { table = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tableView)); }
        @catch (__unused NSException *exception) { table = nil; }
    }
    WAGRMenuApplyTableStyle(table, controller);
}

static void WAGRInstallMainSettingsPresentation(void) {
    if (gWAGRMainPresentationInstalled) return;
    Class cls = NSClassFromString(@"WAGRMainSettingsVC");
    if (!cls) return;

    Method load = class_getInstanceMethod(cls, @selector(viewDidLoad));
    if (!load || method_getNumberOfArguments(load) != 2) return;

    IMP oldLoad = method_setImplementation(load, (IMP)hook_WAGRMainViewDidLoad);
    if (!oldLoad || oldLoad == (IMP)hook_WAGRMainViewDidLoad) return;
    orig_WAGRMainViewDidLoad = (void (*)(id, SEL))oldLoad;
    gWAGRMainPresentationInstalled = YES;
    WAGRLogAppend(@"[UI] WAGRMainSettingsVC native iOS presentation installed");
}

__attribute__((constructor))
static void WAGRMainSettingsPresentationCtor(void) {
    @autoreleasepool { WAGRInstallMainSettingsPresentation(); }
}
