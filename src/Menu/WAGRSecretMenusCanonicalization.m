#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// SecretMenus predates the canonical Features / Experimentos submenus. Keep its
// Me-Tab bundle and diagnostics, but hide the old Internal and Aura masters so
// there is only one UI owner for those feature families.

static NSInteger (*orig_rows)(id, SEL, UITableView *, NSInteger) = NULL;
static UITableViewCell *(*orig_cell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*orig_select)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static NSIndexPath *WAGRSecretCanonicalIndexPath(NSIndexPath *indexPath) {
    if (!indexPath || indexPath.section != 0) return indexPath;
    return [NSIndexPath indexPathForRow:indexPath.row + 2 inSection:indexPath.section];
}

static NSInteger WAGRSecretRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger original = orig_rows ? orig_rows(self, _cmd, tableView, section) : 0;
    if (section == 0 && original >= 3) return original - 2;
    return original;
}

static UITableViewCell *WAGRSecretCell(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    return orig_cell ? orig_cell(self, _cmd, tableView, WAGRSecretCanonicalIndexPath(indexPath)) : nil;
}

static void WAGRSecretSelect(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (orig_select) orig_select(self, _cmd, tableView, WAGRSecretCanonicalIndexPath(indexPath));
}

static void WAGRSecretCanonicalInstall(void) {
    Class cls = NSClassFromString(@"WAGRSecretMenusVC");
    if (!cls) return;

    Method rows = class_getInstanceMethod(cls, @selector(tableView:numberOfRowsInSection:));
    if (rows && method_getImplementation(rows) != (IMP)WAGRSecretRows) {
        orig_rows = (NSInteger (*)(id, SEL, UITableView *, NSInteger))method_getImplementation(rows);
        method_setImplementation(rows, (IMP)WAGRSecretRows);
    }

    Method cell = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    if (cell && method_getImplementation(cell) != (IMP)WAGRSecretCell) {
        orig_cell = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(cell);
        method_setImplementation(cell, (IMP)WAGRSecretCell);
    }

    Method select = class_getInstanceMethod(cls, @selector(tableView:didSelectRowAtIndexPath:));
    if (select && method_getImplementation(select) != (IMP)WAGRSecretSelect) {
        orig_select = (void (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(select);
        method_setImplementation(select, (IMP)WAGRSecretSelect);
    }
}

__attribute__((constructor))
static void WAGRSecretCanonicalCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRSecretCanonicalInstall(); });
    }
}
