#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "WAGRScopedReset.h"

static UITableViewCell *(*gWAGRResetOrigCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*gWAGRResetOrigSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL gWAGRResetUIInstalled = NO;

static BOOL WAGRResetIsResetTitle(NSString *title) {
    return [title isEqualToString:@"Reset WATweaks"] ||
           [title isEqualToString:@"Remover tweaks"];
}

static UITableViewCell *WAGRResetMainCell(id self, SEL _cmd,
                                          UITableView *table,
                                          NSIndexPath *indexPath) {
    UITableViewCell *cell = gWAGRResetOrigCell
        ? gWAGRResetOrigCell(self, _cmd, table, indexPath)
        : nil;
    if (WAGRResetIsResetTitle(cell.textLabel.text)) {
        cell.textLabel.text = @"Remover tweaks";
        cell.accessibilityLabel = @"Remover tweaks por categoria";
    }
    return cell;
}

static void WAGRResetMainSelect(id self, SEL _cmd,
                                UITableView *table,
                                NSIndexPath *indexPath) {
    UITableViewCell *cell = [table cellForRowAtIndexPath:indexPath];
    if (WAGRResetIsResetTitle(cell.textLabel.text)) {
        [table deselectRowAtIndexPath:indexPath animated:YES];
        WAGRPresentScopedReset((UIViewController *)self);
        return;
    }
    if (gWAGRResetOrigSelect) gWAGRResetOrigSelect(self, _cmd, table, indexPath);
}

static void WAGRResetInstallUI(void) {
    if (gWAGRResetUIInstalled) return;
    Class cls = NSClassFromString(@"WAGRMainSettingsVC");
    if (!cls) return;

    Method cell = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    Method select = class_getInstanceMethod(cls, @selector(tableView:didSelectRowAtIndexPath:));
    if (!cell || !select) return;

    IMP cellIMP = method_getImplementation(cell);
    IMP selectIMP = method_getImplementation(select);
    if (cellIMP == (IMP)WAGRResetMainCell || selectIMP == (IMP)WAGRResetMainSelect) {
        gWAGRResetUIInstalled = YES;
        return;
    }

    gWAGRResetOrigCell = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))cellIMP;
    gWAGRResetOrigSelect = (void (*)(id, SEL, UITableView *, NSIndexPath *))selectIMP;
    method_setImplementation(cell, (IMP)WAGRResetMainCell);
    method_setImplementation(select, (IMP)WAGRResetMainSelect);
    gWAGRResetUIInstalled = YES;
}

__attribute__((constructor))
static void WAGRScopedResetUICtor(void) {
    @autoreleasepool {
        WAGRResetInstallUI();
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRResetInstallUI(); });
    }
}
