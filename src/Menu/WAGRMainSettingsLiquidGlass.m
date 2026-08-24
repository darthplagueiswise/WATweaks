#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRLog.h"

// WAGRMainSettingsVC is an inset-grouped UIKit table. On iOS 26 the native
// UINavigationController / UIBarButtonItems already adopt Liquid Glass. Keep the
// content rows as ordinary grouped rows and only normalize the table/chrome.
//
// Important: WAGRMainSettingsVC historically hard-coded 60 pt rows and the
// shared theme could expand Body Dynamic Type. That produced rows materially
// larger than WhatsApp Settings on the same device. This presentation layer is
// the final authority for the main sheet geometry so later model patches cannot
// accidentally inflate it again.

static void (*orig_WAGRMainViewDidLoad)(id, SEL) = NULL;
static BOOL gWAGRMainPresentationInstalled = NO;

static const CGFloat kWAGRMainNativeRowHeight = 52.0;

static CGFloat WAGRMainRowHeight(__unused id self,
                                 __unused SEL _cmd,
                                 __unused UITableView *table,
                                 __unused NSIndexPath *indexPath) {
    return kWAGRMainNativeRowHeight;
}

static CGFloat WAGRMainHeaderHeight(__unused id self,
                                    __unused SEL _cmd,
                                    __unused UITableView *table,
                                    NSInteger section) {
    return section == 0 ? 9.0 : 22.0;
}

static CGFloat WAGRMainFooterHeight(__unused id self,
                                    __unused SEL _cmd,
                                    __unused UITableView *table,
                                    __unused NSInteger section) {
    return 4.0;
}

static void WAGRMainWillDisplayCell(__unused id self,
                                    __unused SEL _cmd,
                                    __unused UITableView *table,
                                    UITableViewCell *cell,
                                    __unused NSIndexPath *indexPath) {
    if (!cell) return;

    // Use a fixed compact text size for this diagnostic/settings sheet. The
    // surrounding WhatsApp UI already applies the user's accessibility scaling;
    // applying preferred Body again here made the injected rows disproportionately
    // large compared with their native neighbors.
    cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    if (cell.imageView.image) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                             weight:UIImageSymbolWeightRegular
                                                              scale:UIImageSymbolScaleMedium];
        UIImage *image = [cell.imageView.image imageByApplyingSymbolConfiguration:configuration];
        if (image) cell.imageView.image = image;
        cell.imageView.tintColor = UIColor.labelColor;
    }
}

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
    if (table) {
        table.estimatedRowHeight = kWAGRMainNativeRowHeight;
        table.rowHeight = kWAGRMainNativeRowHeight;
        if (@available(iOS 15.0, *)) table.sectionHeaderTopPadding = 0.0;
    }
}

static void WAGRReplaceInstanceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method) {
        if (method_getImplementation(method) != replacement) {
            method_setImplementation(method, replacement);
        }
        return;
    }

    // These are optional UITableViewDelegate methods. If the controller does not
    // already implement one, adding it to the runtime method table is sideload-safe
    // and avoids touching executable pages.
    const char *types = NULL;
    if (selector == @selector(tableView:willDisplayCell:forRowAtIndexPath:)) {
        types = "v@:@@@";
    } else if (selector == @selector(tableView:heightForRowAtIndexPath:)) {
        types = "d@:@@";
    } else if (selector == @selector(tableView:heightForHeaderInSection:) ||
               selector == @selector(tableView:heightForFooterInSection:)) {
        types = "d@:@q";
    }
    if (types) class_addMethod(cls, selector, replacement, types);
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

    WAGRReplaceInstanceMethod(cls, @selector(tableView:heightForRowAtIndexPath:),
                              (IMP)WAGRMainRowHeight);
    WAGRReplaceInstanceMethod(cls, @selector(tableView:heightForHeaderInSection:),
                              (IMP)WAGRMainHeaderHeight);
    WAGRReplaceInstanceMethod(cls, @selector(tableView:heightForFooterInSection:),
                              (IMP)WAGRMainFooterHeight);
    WAGRReplaceInstanceMethod(cls, @selector(tableView:willDisplayCell:forRowAtIndexPath:),
                              (IMP)WAGRMainWillDisplayCell);

    gWAGRMainPresentationInstalled = YES;
    WAGRLogAppend(@"[UI] WAGRMainSettingsVC compact WhatsApp-style presentation installed");
}

__attribute__((constructor))
static void WAGRMainSettingsPresentationCtor(void) {
    @autoreleasepool { WAGRInstallMainSettingsPresentation(); }
}
