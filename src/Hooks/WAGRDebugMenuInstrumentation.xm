// WAGRDebugMenuInstrumentation.xm
// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic owner for WhatsApp's native WADebugViewController menu assembly.
// This does not force rows and does not mutate cells. It only instruments the
// native Developer menu after the user opens it, then logs the actual table
// dataSource/delegate classes, sections, rows, cell titles and backing arrays.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../Runtime/WAGRLog.h"

// ── IMP types ────────────────────────────────────────────────────────────────
typedef void      (*VoidIMP)(id, SEL);
typedef void      (*VoidBoolIMP)(id, SEL, BOOL);
typedef NSInteger (*SectionsIMP)(id, SEL, id);
typedef NSInteger (*RowsIMP)(id, SEL, id, NSInteger);
typedef id        (*CellIMP)(id, SEL, id, id);
typedef id        (*TitleIMP)(id, SEL, id, NSInteger);
typedef id        (*ObjectIMP)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *gWAGRDMOrig = nil;
static NSMutableSet<NSString *> *gWAGRDMInstalled = nil;
static NSMutableSet<NSString *> *gWAGRDMObservedClasses = nil;
static BOOL gWAGRDMBaseInstalled = NO;

static NSString *WAGRDMKey(Class cls, SEL sel, NSString *kind) {
    return [NSString stringWithFormat:@"%@|%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel), kind ?: @"?"];
}

static IMP WAGRDMOrigForClass(Class cls, SEL sel, NSString *kind) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        NSString *key = WAGRDMKey(c, sel, kind);
        NSValue *v = gWAGRDMOrig[key];
        if (v) return (IMP)[v pointerValue];
    }
    return NULL;
}

static NSString *WAGRDMShort(id obj) {
    if (!obj) return @"nil";
    NSString *cls = NSStringFromClass([obj class]) ?: @"?";
    if ([obj isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"%@:'%@'", cls, obj];
    if ([obj isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"%@ count=%lu", cls, (unsigned long)[(NSArray *)obj count]];
    if ([obj isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"%@ count=%lu", cls, (unsigned long)[(NSDictionary *)obj count]];
    if ([obj isKindOfClass:NSSet.class]) return [NSString stringWithFormat:@"%@ count=%lu", cls, (unsigned long)[(NSSet *)obj count]];
    return [NSString stringWithFormat:@"%@ (%p)", cls, (__bridge void *)obj];
}

static NSString *WAGRDMCellText(id cellObj) {
    if (![cellObj isKindOfClass:UITableViewCell.class]) {
        return cellObj ? [NSString stringWithFormat:@"%@", NSStringFromClass([cellObj class])] : @"nil";
    }
    UITableViewCell *cell = (UITableViewCell *)cellObj;
    NSString *title = cell.textLabel.text ?: @"";
    NSString *detail = cell.detailTextLabel.text ?: @"";
    NSString *reuse = cell.reuseIdentifier ?: @"";
    NSString *acc = cell.accessibilityIdentifier ?: @"";
    return [NSString stringWithFormat:@"class=%@ reuse='%@' title='%@' detail='%@' acc='%@'",
            NSStringFromClass([cell class]), reuse, title, detail, acc];
}

static NSString *WAGRDMIndexPath(id ipObj) {
    if (![ipObj isKindOfClass:NSIndexPath.class]) return @"?";
    NSIndexPath *ip = (NSIndexPath *)ipObj;
    NSInteger section = [ip respondsToSelector:@selector(section)] ? [(id)ip section] : -1;
    NSInteger row = [ip respondsToSelector:@selector(row)] ? [(id)ip row] : -1;
    return [NSString stringWithFormat:@"%ld/%ld", (long)section, (long)row];
}

static void WAGRDMLogCollectionPreview(id obj, NSString *owner, NSString *selName) {
    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ -> NSArray count=%lu", owner, selName, (unsigned long)arr.count);
        NSUInteger limit = MIN((NSUInteger)12, arr.count);
        for (NSUInteger i = 0; i < limit; i++) {
            id item = arr[i];
            WAGRLogAppendF(@"[DebugMenuSpy]   %@.%@[%lu] %@ desc=%@",
                           owner, selName, (unsigned long)i,
                           NSStringFromClass([item class]), [item description]);
        }
        return;
    }

    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ -> NSDictionary count=%lu keys=%@",
                       owner, selName, (unsigned long)dict.count, [dict.allKeys componentsJoinedByString:@", "]);
        return;
    }

    WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ -> %@", owner, selName, WAGRDMShort(obj));
}

static NSArray<UITableView *> *WAGRDMFindTablesInView(UIView *view) {
    if (!view) return @[];
    NSMutableArray<UITableView *> *out = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:UITableView.class]) [out addObject:(UITableView *)v];
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return out;
}

static BOOL WAGRDMInstallHook(Class cls, SEL sel, IMP replacement, NSString *kind) {
    if (!cls || !sel || !replacement || !kind.length) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (!gWAGRDMOrig) gWAGRDMOrig = [NSMutableDictionary dictionary];
    if (!gWAGRDMInstalled) gWAGRDMInstalled = [NSMutableSet set];
    NSString *key = WAGRDMKey(cls, sel, kind);
    if ([gWAGRDMInstalled containsObject:key]) return YES;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, replacement, &orig);
    if (!orig) return NO;
    gWAGRDMOrig[key] = [NSValue valueWithPointer:(const void *)orig];
    [gWAGRDMInstalled addObject:key];
    WAGRLogAppendF(@"[DebugMenuSpy] hooked %@.%@ kind=%@", NSStringFromClass(cls), NSStringFromSelector(sel), kind);
    return YES;
}

static void WAGRDebugMenuInstrumentationInspectViewController(id vc, NSString *stage);
static void WAGRDebugMenuInstrumentationInstallTableHooksForClass(Class cls, NSString *source);

// ── Table datasource hooks ──────────────────────────────────────────────────
static NSInteger hookDMDebugNumberOfSections(id self, SEL _cmd, id tableView) {
    SectionsIMP orig = (SectionsIMP)WAGRDMOrigForClass([self class], _cmd, @"sections");
    NSInteger ret = orig ? orig(self, _cmd, tableView) : 1;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ numberOfSectionsInTableView:%@ -> %ld",
                   NSStringFromClass([self class]), NSStringFromClass([tableView class]), (long)ret);
    return ret;
}

static NSInteger hookDMDebugRows(id self, SEL _cmd, id tableView, NSInteger section) {
    RowsIMP orig = (RowsIMP)WAGRDMOrigForClass([self class], _cmd, @"rows");
    NSInteger ret = orig ? orig(self, _cmd, tableView, section) : 0;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ tableView:numberOfRowsInSection:%ld -> %ld",
                   NSStringFromClass([self class]), (long)section, (long)ret);
    return ret;
}

static id hookDMDebugCell(id self, SEL _cmd, id tableView, id indexPath) {
    CellIMP orig = (CellIMP)WAGRDMOrigForClass([self class], _cmd, @"cell");
    id ret = orig ? orig(self, _cmd, tableView, indexPath) : nil;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ cellForRow %@ -> %@",
                   NSStringFromClass([self class]), WAGRDMIndexPath(indexPath), WAGRDMCellText(ret));
    return ret;
}

static id hookDMDebugHeaderTitle(id self, SEL _cmd, id tableView, NSInteger section) {
    TitleIMP orig = (TitleIMP)WAGRDMOrigForClass([self class], _cmd, @"header");
    id ret = orig ? orig(self, _cmd, tableView, section) : nil;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ titleForHeader section=%ld -> %@",
                   NSStringFromClass([self class]), (long)section, ret ?: @"nil");
    return ret;
}

static id hookDMDebugFooterTitle(id self, SEL _cmd, id tableView, NSInteger section) {
    TitleIMP orig = (TitleIMP)WAGRDMOrigForClass([self class], _cmd, @"footer");
    id ret = orig ? orig(self, _cmd, tableView, section) : nil;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ titleForFooter section=%ld -> %@",
                   NSStringFromClass([self class]), (long)section, ret ?: @"nil");
    return ret;
}

// ── WADebugViewController lifecycle hooks ───────────────────────────────────
static void hookDMDebugViewDidLoad(id self, SEL _cmd) {
    VoidIMP orig = (VoidIMP)WAGRDMOrigForClass([self class], _cmd, @"void");
    if (orig) orig(self, _cmd);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewDidLoad", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationInspectViewController(self, @"viewDidLoad");
}

static void hookDMDebugViewWillAppear(id self, SEL _cmd, BOOL animated) {
    VoidBoolIMP orig = (VoidBoolIMP)WAGRDMOrigForClass([self class], _cmd, @"voidBool");
    if (orig) orig(self, _cmd, animated);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewWillAppear", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationInspectViewController(self, @"viewWillAppear");
}

static void hookDMDebugViewDidAppear(id self, SEL _cmd, BOOL animated) {
    VoidBoolIMP orig = (VoidBoolIMP)WAGRDMOrigForClass([self class], _cmd, @"voidBool");
    if (orig) orig(self, _cmd, animated);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewDidAppear", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationInspectViewController(self, @"viewDidAppear");
}

// ── No-arg object selectors: sections/items/provider.debugViewController ────
static id hookDMDebugObjectSelector(id self, SEL _cmd) {
    ObjectIMP orig = (ObjectIMP)WAGRDMOrigForClass([self class], _cmd, @"object");
    id ret = nil;
    @try { ret = orig ? orig(self, _cmd) : nil; } @catch (NSException *ex) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ threw %@: %@",
                       NSStringFromClass([self class]), NSStringFromSelector(_cmd), ex.name, ex.reason);
        ret = nil;
    }
    NSString *owner = NSStringFromClass([self class]);
    NSString *selName = NSStringFromSelector(_cmd);
    WAGRDMLogCollectionPreview(ret, owner, selName);
    if ([ret isKindOfClass:UIViewController.class]) {
        WAGRDebugMenuInstrumentationInspectViewController(ret, [NSString stringWithFormat:@"%@.%@", owner, selName]);
    }
    return ret;
}

static void WAGRDebugMenuInstrumentationInstallObjectHooksForClass(Class cls, NSString *source) {
    if (!cls) return;
    NSArray<NSString *> *selectors = @[
        @"debugViewController",
        @"sections", @"items", @"menuItems",
        @"debugSections", @"debugItems", @"debugMenuItems",
        @"plugins", @"providers", @"rows", @"viewModels"
    ];
    NSUInteger installed = 0;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || method_getNumberOfArguments(m) != 2) continue;
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        if (ret[0] != '@') continue;
        if (WAGRDMInstallHook(cls, sel, (IMP)hookDMDebugObjectSelector, @"object")) installed++;
    }
    if (installed) {
        WAGRLogAppendF(@"[DebugMenuSpy] object probes installed class=%@ source=%@ count=%lu",
                       NSStringFromClass(cls), source ?: @"?", (unsigned long)installed);
    }
}

static void WAGRDebugMenuInstrumentationInstallTableHooksForClass(Class cls, NSString *source) {
    if (!cls) return;
    if (!gWAGRDMObservedClasses) gWAGRDMObservedClasses = [NSMutableSet set];
    NSString *className = NSStringFromClass(cls);
    if (!className.length) return;

    NSUInteger installed = 0;
    installed += WAGRDMInstallHook(cls, NSSelectorFromString(@"numberOfSectionsInTableView:"), (IMP)hookDMDebugNumberOfSections, @"sections") ? 1 : 0;
    installed += WAGRDMInstallHook(cls, NSSelectorFromString(@"tableView:numberOfRowsInSection:"), (IMP)hookDMDebugRows, @"rows") ? 1 : 0;
    installed += WAGRDMInstallHook(cls, NSSelectorFromString(@"tableView:cellForRowAtIndexPath:"), (IMP)hookDMDebugCell, @"cell") ? 1 : 0;
    installed += WAGRDMInstallHook(cls, NSSelectorFromString(@"tableView:titleForHeaderInSection:"), (IMP)hookDMDebugHeaderTitle, @"header") ? 1 : 0;
    installed += WAGRDMInstallHook(cls, NSSelectorFromString(@"tableView:titleForFooterInSection:"), (IMP)hookDMDebugFooterTitle, @"footer") ? 1 : 0;
    WAGRDebugMenuInstrumentationInstallObjectHooksForClass(cls, source);

    if (installed || ![gWAGRDMObservedClasses containsObject:className]) {
        [gWAGRDMObservedClasses addObject:className];
        WAGRLogAppendF(@"[DebugMenuSpy] table owner class=%@ source=%@ tableHooks=%lu",
                       className, source ?: @"?", (unsigned long)installed);
    }
}

static void WAGRDebugMenuInstrumentationInspectViewController(id vc, NSString *stage) {
    if (![vc isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)vc;
    Class cls = [controller class];
    WAGRDebugMenuInstrumentationInstallTableHooksForClass(cls, stage ?: @"vc");
    WAGRDebugMenuInstrumentationInstallObjectHooksForClass(cls, stage ?: @"vc");

    NSArray<UITableView *> *tables = WAGRDMFindTablesInView(controller.view);
    WAGRLogAppendF(@"[DebugMenuSpy] inspect %@ stage=%@ tables=%lu title='%@'",
                   NSStringFromClass(cls), stage ?: @"?", (unsigned long)tables.count, controller.title ?: @"");

    for (UITableView *table in tables) {
        id ds = table.dataSource;
        id dg = table.delegate;
        WAGRLogAppendF(@"[DebugMenuSpy] table=%@ (%p) dataSource=%@ (%p) delegate=%@ (%p)",
                       NSStringFromClass([table class]), (__bridge void *)table,
                       ds ? NSStringFromClass([ds class]) : @"nil", (__bridge void *)ds,
                       dg ? NSStringFromClass([dg class]) : @"nil", (__bridge void *)dg);
        if (ds) WAGRDebugMenuInstrumentationInstallTableHooksForClass([ds class], @"table.dataSource");
        if (dg && dg != ds) WAGRDebugMenuInstrumentationInstallTableHooksForClass([dg class], @"table.delegate");

        @try {
            NSInteger sections = [ds respondsToSelector:@selector(numberOfSectionsInTableView:)] ?
                ((NSInteger (*)(id, SEL, id))objc_msgSend)(ds, @selector(numberOfSectionsInTableView:), table) : 1;
            WAGRLogAppendF(@"[DebugMenuSpy] snapshot table sections=%ld", (long)sections);
            NSInteger cappedSections = MIN((NSInteger)20, sections);
            for (NSInteger s = 0; s < cappedSections; s++) {
                NSInteger rows = [ds respondsToSelector:@selector(tableView:numberOfRowsInSection:)] ?
                    ((NSInteger (*)(id, SEL, id, NSInteger))objc_msgSend)(ds, @selector(tableView:numberOfRowsInSection:), table, s) : 0;
                WAGRLogAppendF(@"[DebugMenuSpy] snapshot section=%ld rows=%ld", (long)s, (long)rows);
            }
        } @catch (NSException *ex) {
            WAGRLogAppendF(@"[DebugMenuSpy] snapshot threw %@: %@", ex.name, ex.reason);
        }
    }
}

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void) {
    if (!gWAGRDMOrig) gWAGRDMOrig = [NSMutableDictionary dictionary];
    if (!gWAGRDMInstalled) gWAGRDMInstalled = [NSMutableSet set];
    if (!gWAGRDMObservedClasses) gWAGRDMObservedClasses = [NSMutableSet set];

    Class debugCls = NSClassFromString(@"WADebugViewController");
    if (debugCls) {
        WAGRDMInstallHook(debugCls, NSSelectorFromString(@"viewDidLoad"), (IMP)hookDMDebugViewDidLoad, @"void");
        WAGRDMInstallHook(debugCls, NSSelectorFromString(@"viewWillAppear:"), (IMP)hookDMDebugViewWillAppear, @"voidBool");
        WAGRDMInstallHook(debugCls, NSSelectorFromString(@"viewDidAppear:"), (IMP)hookDMDebugViewDidAppear, @"voidBool");
        WAGRDebugMenuInstrumentationInstallTableHooksForClass(debugCls, @"base-debug-vc");
        gWAGRDMBaseInstalled = YES;
    }

    Class providerCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    if (providerCls) WAGRDebugMenuInstrumentationInstallObjectHooksForClass(providerCls, @"base-provider");

    WAGRLogAppendF(@"[DebugMenuSpy] ensure installed debugVC=%@ provider=%@ totalHooks=%lu",
                   debugCls ? @"YES" : @"NO",
                   providerCls ? @"YES" : @"NO",
                   (unsigned long)gWAGRDMInstalled.count);
}

extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"DebugMenuSpy baseInstalled=%@\ninstalled hooks=%lu\nobserved classes=%@",
            gWAGRDMBaseInstalled ? @"YES" : @"NO",
            (unsigned long)gWAGRDMInstalled.count,
            [[gWAGRDMObservedClasses allObjects] componentsJoinedByString:@", "] ?: @""];
}

__attribute__((constructor))
static void WAGRDebugMenuInstrumentationCtor(void) {
    @autoreleasepool {
        WAGRDebugMenuInstrumentationEnsureInstalled();
    }
}
