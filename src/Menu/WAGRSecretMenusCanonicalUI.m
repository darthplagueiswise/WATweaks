#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// WAGRSecretMenusVC still contains legacy Internal/Employee and Aura master rows.
// Those are duplicate state surfaces now that Features / Experimentos owns the
// canonical curated UI and WAAB values live in WAGRRuntimeValueStore. Preserve
// Secret Menus diagnostics and the unrelated Me-Tab bundle, but do not expose a
// second Internal/Aura control surface.

static NSInteger (*gWAGRSecretRowsOriginal)(id, SEL, UITableView *, NSInteger) = NULL;
static UITableViewCell *(*gWAGRSecretCellOriginal)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static NSString *(*gWAGRSecretHeaderOriginal)(id, SEL, UITableView *, NSInteger) = NULL;

static NSInteger WAGRSecretCanonicalRows(id self,
                                         SEL _cmd,
                                         UITableView *tableView,
                                         NSInteger section) {
    NSInteger count = gWAGRSecretRowsOriginal
        ? gWAGRSecretRowsOriginal(self, _cmd, tableView, section) : 0;
    // Original master rows: Internal/Employee, Aura, Me-Tab. Only Me-Tab remains.
    if (section == 0 && count >= 3) return count - 2;
    return count;
}

static NSIndexPath *WAGRSecretCanonicalSourceIndexPath(NSIndexPath *indexPath) {
    if (!indexPath || indexPath.section != 0) return indexPath;
    return [NSIndexPath indexPathForRow:indexPath.row + 2 inSection:indexPath.section];
}

static UITableViewCell *WAGRSecretCanonicalCell(id self,
                                                SEL _cmd,
                                                UITableView *tableView,
                                                NSIndexPath *indexPath) {
    NSIndexPath *source = WAGRSecretCanonicalSourceIndexPath(indexPath);
    return gWAGRSecretCellOriginal
        ? gWAGRSecretCellOriginal(self, _cmd, tableView, source)
        : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

static NSString *WAGRSecretCanonicalHeader(id self,
                                           SEL _cmd,
                                           UITableView *tableView,
                                           NSInteger section) {
    if (section == 0) return @"Outros bundles";
    return gWAGRSecretHeaderOriginal
        ? gWAGRSecretHeaderOriginal(self, _cmd, tableView, section) : nil;
}

static void WAGRSecretInstallCanonicalPresentation(void) {
    Class cls = NSClassFromString(@"WAGRSecretMenusVC");
    if (!cls) return;

    SEL rowsSelector = @selector(tableView:numberOfRowsInSection:);
    Method rows = class_getInstanceMethod(cls, rowsSelector);
    if (rows && method_getImplementation(rows) != (IMP)WAGRSecretCanonicalRows) {
        gWAGRSecretRowsOriginal =
            (NSInteger (*)(id, SEL, UITableView *, NSInteger))method_getImplementation(rows);
        method_setImplementation(rows, (IMP)WAGRSecretCanonicalRows);
    }

    SEL cellSelector = @selector(tableView:cellForRowAtIndexPath:);
    Method cell = class_getInstanceMethod(cls, cellSelector);
    if (cell && method_getImplementation(cell) != (IMP)WAGRSecretCanonicalCell) {
        gWAGRSecretCellOriginal =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(cell);
        method_setImplementation(cell, (IMP)WAGRSecretCanonicalCell);
    }

    SEL headerSelector = @selector(tableView:titleForHeaderInSection:);
    Method header = class_getInstanceMethod(cls, headerSelector);
    if (header && method_getImplementation(header) != (IMP)WAGRSecretCanonicalHeader) {
        gWAGRSecretHeaderOriginal =
            (NSString *(*)(id, SEL, UITableView *, NSInteger))method_getImplementation(header);
        method_setImplementation(header, (IMP)WAGRSecretCanonicalHeader);
    }
}

__attribute__((constructor))
static void WAGRSecretCanonicalUICtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            WAGRSecretInstallCanonicalPresentation();
        });
    }
}
