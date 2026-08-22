#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRLog.h"

// WAGRMainSettingsVC predates the shared theme helpers and still builds plain
// grouped cells. Keep its behavior/model intact and wrap only its presentation
// methods through the Objective-C method table (no inline __TEXT patching).

static void (*orig_WAGRMainViewDidLoad)(id, SEL) = NULL;
static UITableViewCell *(*orig_WAGRMainCellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL gWAGRMainGlassInstalled = NO;

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

static UITableViewCell *hook_WAGRMainCellForRow(id self,
                                                 SEL _cmd,
                                                 UITableView *tableView,
                                                 NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_WAGRMainCellForRow
        ? orig_WAGRMainCellForRow(self, _cmd, tableView, indexPath) : nil;
    if (!cell) return nil;

    NSString *key = cell.textLabel.text ?: @"watweaks";
    UIColor *explicitColor = cell.textLabel.textColor;
    BOOL destructive = [explicitColor isEqual:UIColor.systemRedColor] ||
                       [key.lowercaseString containsString:@"reset"] ||
                       [key.lowercaseString containsString:@"reiniciar"];

    WAGRMenuApplyCellStyle(cell, indexPath.row, key);
    if (destructive) cell.textLabel.textColor = UIColor.systemRedColor;
    return cell;
}

static void WAGRInstallMainSettingsGlass(void) {
    if (gWAGRMainGlassInstalled) return;
    Class cls = NSClassFromString(@"WAGRMainSettingsVC");
    if (!cls) return;

    Method load = class_getInstanceMethod(cls, @selector(viewDidLoad));
    Method cell = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    if (!load || !cell) return;

    IMP oldLoad = method_setImplementation(load, (IMP)hook_WAGRMainViewDidLoad);
    IMP oldCell = method_setImplementation(cell, (IMP)hook_WAGRMainCellForRow);
    if (!oldLoad || !oldCell ||
        oldLoad == (IMP)hook_WAGRMainViewDidLoad ||
        oldCell == (IMP)hook_WAGRMainCellForRow) return;

    orig_WAGRMainViewDidLoad = (void (*)(id, SEL))oldLoad;
    orig_WAGRMainCellForRow = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))oldCell;
    gWAGRMainGlassInstalled = YES;
    WAGRLogAppend(@"[UI][LiquidGlass] WAGRMainSettingsVC modern theme installed");
}

__attribute__((constructor))
static void WAGRMainSettingsLiquidGlassCtor(void) {
    @autoreleasepool { WAGRInstallMainSettingsGlass(); }
}
