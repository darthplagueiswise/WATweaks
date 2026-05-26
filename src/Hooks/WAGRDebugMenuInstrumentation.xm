// WAGRDebugMenuInstrumentation.xm
// Diagnostic owner for WhatsApp's native WADebugViewController menu assembly.
// New WhatsApp(11) target: the useful choke point is -createSections, not only
// tableView datasource callbacks. This file is diagnostic-only: no row forcing.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../Runtime/WAGRLog.h"

typedef void      (*WAGRDMVoidIMP)(id, SEL);
typedef void      (*WAGRDMVoidBoolIMP)(id, SEL, BOOL);
typedef id        (*WAGRDMObjectIMP)(id, SEL);
typedef NSInteger (*WAGRDMSectionsIMP)(id, SEL, id);
typedef NSInteger (*WAGRDMRowsIMP)(id, SEL, id, NSInteger);
typedef id        (*WAGRDMCellIMP)(id, SEL, id, id);
typedef id        (*WAGRDMTitleIMP)(id, SEL, id, NSInteger);

static NSMutableDictionary<NSString *, NSValue *> *gWAGRDMOrig;
static NSMutableSet<NSString *> *gWAGRDMInstalled;
static NSMutableSet<NSString *> *gWAGRDMObservedClasses;
static BOOL gWAGRDMBaseInstalled = NO;

static NSString *WAGRDMKey(Class cls, SEL sel, NSString *kind) {
    return [NSString stringWithFormat:@"%@|%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel), kind ?: @"?"];
}

static IMP WAGRDMOrig(Class cls, SEL sel, NSString *kind) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        NSValue *v = gWAGRDMOrig[WAGRDMKey(c, sel, kind)];
        if (v) return (IMP)[v pointerValue];
    }
    return NULL;
}

static BOOL WAGRDMMethodReturns(Method m, char wanted) {
    if (!m) return NO;
    char ret[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == wanted;
}

static BOOL WAGRDMInstall(Class cls, SEL sel, IMP repl, NSString *kind) {
    if (!cls || !sel || !repl || !kind.length) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (!gWAGRDMOrig) gWAGRDMOrig = [NSMutableDictionary dictionary];
    if (!gWAGRDMInstalled) gWAGRDMInstalled = [NSMutableSet set];

    NSString *key = WAGRDMKey(cls, sel, kind);
    if ([gWAGRDMInstalled containsObject:key]) return YES;

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, repl, &orig);
    if (!orig) return NO;

    gWAGRDMOrig[key] = [NSValue valueWithPointer:(const void *)orig];
    [gWAGRDMInstalled addObject:key];
    WAGRLogAppendF(@"[DebugMenuSpy] hooked %@.%@ kind=%@",
                   NSStringFromClass(cls), NSStringFromSelector(sel), kind);
    return YES;
}

static NSString *WAGRDMShort(id obj) {
    if (!obj) return @"nil";
    if ([obj isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"NSString '%@'", obj];
    if ([obj isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"%@ count=%lu", NSStringFromClass([obj class]), (unsigned long)[(NSArray *)obj count]];
    if ([obj isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"%@ count=%lu", NSStringFromClass([obj class]), (unsigned long)[(NSDictionary *)obj count]];
    if ([obj isKindOfClass:NSSet.class]) return [NSString stringWithFormat:@"%@ count=%lu", NSStringFromClass([obj class]), (unsigned long)[(NSSet *)obj count]];
    return [NSString stringWithFormat:@"%@ (%p)", NSStringFromClass([obj class]), (__bridge void *)obj];
}

static void WAGRDMPreview(id obj, NSString *owner, NSString *name) {
    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ -> NSArray count=%lu", owner, name, (unsigned long)arr.count);
        NSUInteger limit = MIN((NSUInteger)16, arr.count);
        for (NSUInteger i = 0; i < limit; i++) {
            id item = arr[i];
            WAGRLogAppendF(@"[DebugMenuSpy]   %@.%@[%lu] %@ desc=%@",
                           owner, name, (unsigned long)i,
                           item ? NSStringFromClass([item class]) : @"nil",
                           item ? [item description] : @"nil");
        }
        return;
    }

    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ -> NSDictionary count=%lu keys=%@",
                       owner, name, (unsigned long)dict.count, [dict.allKeys componentsJoinedByString:@", "]);
        return;
    }

    WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ -> %@", owner, name, WAGRDMShort(obj));
}

static NSArray<NSString *> *WAGRDMObjectSelectors(void) {
    return @[
        @"debugViewController",
        @"sections", @"items", @"menuItems", @"rows", @"viewModels",
        @"debugSections", @"debugItems", @"debugMenuItems", @"debugMenuSections",
        @"menuSections", @"sectionModels", @"plugins", @"providers",
        @"tableView", @"dataSource", @"delegate"
    ];
}

static NSArray<UITableView *> *WAGRDMFindTables(UIView *view) {
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

static NSString *WAGRDMIndexPath(id obj) {
    if (![obj isKindOfClass:NSIndexPath.class]) return @"?";
    NSIndexPath *ip = (NSIndexPath *)obj;
    return [NSString stringWithFormat:@"%ld/%ld", (long)[(id)ip section], (long)[(id)ip row]];
}

static NSString *WAGRDMCellText(id obj) {
    if (![obj isKindOfClass:UITableViewCell.class]) return WAGRDMShort(obj);
    UITableViewCell *cell = (UITableViewCell *)obj;
    return [NSString stringWithFormat:@"class=%@ reuse='%@' title='%@' detail='%@' acc='%@'",
            NSStringFromClass([cell class]),
            cell.reuseIdentifier ?: @"",
            cell.textLabel.text ?: @"",
            cell.detailTextLabel.text ?: @"",
            cell.accessibilityIdentifier ?: @""];
}

static void WAGRDebugMenuInstrumentationInstallTableHooksForClass(Class cls, NSString *source);
static void WAGRDebugMenuInstrumentationInstallAssemblyHooksForClass(Class cls, NSString *source);
static void WAGRDebugMenuInstrumentationInspectVC(id vc, NSString *stage);
static void WAGRDebugMenuInstrumentationDumpState(id owner, NSString *stage);

static NSInteger hookDMSections(id self, SEL _cmd, id tableView) {
    WAGRDMSectionsIMP orig = (WAGRDMSectionsIMP)WAGRDMOrig([self class], _cmd, @"sections");
    NSInteger ret = orig ? orig(self, _cmd, tableView) : 1;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ numberOfSections -> %ld", NSStringFromClass([self class]), (long)ret);
    return ret;
}

static NSInteger hookDMRows(id self, SEL _cmd, id tableView, NSInteger section) {
    WAGRDMRowsIMP orig = (WAGRDMRowsIMP)WAGRDMOrig([self class], _cmd, @"rows");
    NSInteger ret = orig ? orig(self, _cmd, tableView, section) : 0;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ rows section=%ld -> %ld", NSStringFromClass([self class]), (long)section, (long)ret);
    return ret;
}

static id hookDMCell(id self, SEL _cmd, id tableView, id indexPath) {
    WAGRDMCellIMP orig = (WAGRDMCellIMP)WAGRDMOrig([self class], _cmd, @"cell");
    id ret = orig ? orig(self, _cmd, tableView, indexPath) : nil;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ cell %@ -> %@", NSStringFromClass([self class]), WAGRDMIndexPath(indexPath), WAGRDMCellText(ret));
    return ret;
}

static id hookDMHeader(id self, SEL _cmd, id tableView, NSInteger section) {
    WAGRDMTitleIMP orig = (WAGRDMTitleIMP)WAGRDMOrig([self class], _cmd, @"header");
    id ret = orig ? orig(self, _cmd, tableView, section) : nil;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ header section=%ld -> %@", NSStringFromClass([self class]), (long)section, ret ?: @"nil");
    return ret;
}

static id hookDMFooter(id self, SEL _cmd, id tableView, NSInteger section) {
    WAGRDMTitleIMP orig = (WAGRDMTitleIMP)WAGRDMOrig([self class], _cmd, @"footer");
    id ret = orig ? orig(self, _cmd, tableView, section) : nil;
    WAGRLogAppendF(@"[DebugMenuSpy] %@ footer section=%ld -> %@", NSStringFromClass([self class]), (long)section, ret ?: @"nil");
    return ret;
}

static id hookDMObject(id self, SEL _cmd) {
    WAGRDMObjectIMP orig = (WAGRDMObjectIMP)WAGRDMOrig([self class], _cmd, @"object");
    id ret = nil;
    @try { ret = orig ? orig(self, _cmd) : nil; }
    @catch (NSException *ex) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ threw %@: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), ex.name, ex.reason);
    }
    WAGRDMPreview(ret, NSStringFromClass([self class]), NSStringFromSelector(_cmd));
    if ([ret isKindOfClass:UIViewController.class]) WAGRDebugMenuInstrumentationInspectVC(ret, NSStringFromSelector(_cmd));
    return ret;
}

static void hookDMViewDidLoad(id self, SEL _cmd) {
    WAGRDMVoidIMP orig = (WAGRDMVoidIMP)WAGRDMOrig([self class], _cmd, @"void");
    if (orig) orig(self, _cmd);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewDidLoad", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"viewDidLoad");
    WAGRDebugMenuInstrumentationInspectVC(self, @"viewDidLoad");
}

static void hookDMViewWillAppear(id self, SEL _cmd, BOOL animated) {
    WAGRDMVoidBoolIMP orig = (WAGRDMVoidBoolIMP)WAGRDMOrig([self class], _cmd, @"voidBool");
    if (orig) orig(self, _cmd, animated);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewWillAppear", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"viewWillAppear");
    WAGRDebugMenuInstrumentationInspectVC(self, @"viewWillAppear");
}

static void hookDMViewDidAppear(id self, SEL _cmd, BOOL animated) {
    WAGRDMVoidBoolIMP orig = (WAGRDMVoidBoolIMP)WAGRDMOrig([self class], _cmd, @"voidBool");
    if (orig) orig(self, _cmd, animated);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewDidAppear", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"viewDidAppear");
    WAGRDebugMenuInstrumentationInspectVC(self, @"viewDidAppear");
}

static void hookDMSetUpTableView(id self, SEL _cmd) {
    WAGRDMVoidIMP orig = (WAGRDMVoidIMP)WAGRDMOrig([self class], _cmd, @"setUpTableView");
    WAGRLogAppendF(@"[DebugMenuSpy] %@ setUpTableView before", NSStringFromClass([self class]));
    if (orig) orig(self, _cmd);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ setUpTableView after", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"after setUpTableView");
    WAGRDebugMenuInstrumentationInspectVC(self, @"after setUpTableView");
}

static void hookDMCreateSectionsVoid(id self, SEL _cmd) {
    WAGRDMVoidIMP orig = (WAGRDMVoidIMP)WAGRDMOrig([self class], _cmd, @"createSectionsVoid");
    WAGRLogAppendF(@"[DebugMenuSpy] %@ createSections before return=void", NSStringFromClass([self class]));
    if (orig) orig(self, _cmd);
    WAGRLogAppendF(@"[DebugMenuSpy] %@ createSections after return=void", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"after createSections");
    WAGRDebugMenuInstrumentationInspectVC(self, @"after createSections");
}

static id hookDMCreateSectionsObject(id self, SEL _cmd) {
    WAGRDMObjectIMP orig = (WAGRDMObjectIMP)WAGRDMOrig([self class], _cmd, @"createSectionsObject");
    WAGRLogAppendF(@"[DebugMenuSpy] %@ createSections before return=object", NSStringFromClass([self class]));
    id ret = nil;
    @try { ret = orig ? orig(self, _cmd) : nil; }
    @catch (NSException *ex) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@ createSections threw %@: %@", NSStringFromClass([self class]), ex.name, ex.reason);
    }
    WAGRDMPreview(ret, NSStringFromClass([self class]), @"createSections.ret");
    WAGRDebugMenuInstrumentationDumpState(self, @"after createSections");
    WAGRDebugMenuInstrumentationInspectVC(self, @"after createSections");
    return ret;
}

static void WAGRDebugMenuInstrumentationInstallObjectHooksForClass(Class cls, NSString *source) {
    if (!cls) return;
    NSUInteger installed = 0;
    for (NSString *name in WAGRDMObjectSelectors()) {
        SEL sel = NSSelectorFromString(name);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || method_getNumberOfArguments(m) != 2 || !WAGRDMMethodReturns(m, '@')) continue;
        if (WAGRDMInstall(cls, sel, (IMP)hookDMObject, @"object")) installed++;
    }
    if (installed) {
        WAGRLogAppendF(@"[DebugMenuSpy] object probes installed class=%@ source=%@ count=%lu",
                       NSStringFromClass(cls), source ?: @"?", (unsigned long)installed);
    }
}

static void WAGRDebugMenuInstrumentationInstallAssemblyHooksForClass(Class cls, NSString *source) {
    if (!cls) return;

    SEL setupSel = NSSelectorFromString(@"setUpTableView");
    Method setup = class_getInstanceMethod(cls, setupSel);
    if (setup && method_getNumberOfArguments(setup) == 2 && WAGRDMMethodReturns(setup, 'v')) {
        WAGRDMInstall(cls, setupSel, (IMP)hookDMSetUpTableView, @"setUpTableView");
    }

    SEL createSel = NSSelectorFromString(@"createSections");
    Method create = class_getInstanceMethod(cls, createSel);
    if (create && method_getNumberOfArguments(create) == 2) {
        if (WAGRDMMethodReturns(create, 'v')) {
            WAGRDMInstall(cls, createSel, (IMP)hookDMCreateSectionsVoid, @"createSectionsVoid");
        } else if (WAGRDMMethodReturns(create, '@')) {
            WAGRDMInstall(cls, createSel, (IMP)hookDMCreateSectionsObject, @"createSectionsObject");
        } else {
            char ret[32] = {0};
            method_getReturnType(create, ret, sizeof(ret));
            WAGRLogAppendF(@"[DebugMenuSpy] skipped %@.createSections unsupported return='%s'", NSStringFromClass(cls), ret);
        }
    }

    if (setup || create) {
        WAGRLogAppendF(@"[DebugMenuSpy] assembly probes checked class=%@ source=%@ setup=%@ create=%@",
                       NSStringFromClass(cls), source ?: @"?",
                       setup ? @"YES" : @"NO", create ? @"YES" : @"NO");
    }
}

static void WAGRDebugMenuInstrumentationInstallTableHooksForClass(Class cls, NSString *source) {
    if (!cls) return;
    if (!gWAGRDMObservedClasses) gWAGRDMObservedClasses = [NSMutableSet set];

    NSUInteger tableHooks = 0;
    tableHooks += WAGRDMInstall(cls, NSSelectorFromString(@"numberOfSectionsInTableView:"), (IMP)hookDMSections, @"sections") ? 1 : 0;
    tableHooks += WAGRDMInstall(cls, NSSelectorFromString(@"tableView:numberOfRowsInSection:"), (IMP)hookDMRows, @"rows") ? 1 : 0;
    tableHooks += WAGRDMInstall(cls, NSSelectorFromString(@"tableView:cellForRowAtIndexPath:"), (IMP)hookDMCell, @"cell") ? 1 : 0;
    tableHooks += WAGRDMInstall(cls, NSSelectorFromString(@"tableView:titleForHeaderInSection:"), (IMP)hookDMHeader, @"header") ? 1 : 0;
    tableHooks += WAGRDMInstall(cls, NSSelectorFromString(@"tableView:titleForFooterInSection:"), (IMP)hookDMFooter, @"footer") ? 1 : 0;

    WAGRDebugMenuInstrumentationInstallAssemblyHooksForClass(cls, source);
    WAGRDebugMenuInstrumentationInstallObjectHooksForClass(cls, source);

    NSString *name = NSStringFromClass(cls);
    if (tableHooks || ![gWAGRDMObservedClasses containsObject:name]) {
        [gWAGRDMObservedClasses addObject:name];
        WAGRLogAppendF(@"[DebugMenuSpy] table owner class=%@ source=%@ tableHooks=%lu",
                       name, source ?: @"?", (unsigned long)tableHooks);
    }
}

static void WAGRDebugMenuInstrumentationDumpIvars(id owner, NSString *stage) {
    if (!owner) return;
    for (Class cls = [owner class]; cls && cls != UIViewController.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            Ivar iv = ivars[i];
            const char *nameC = ivar_getName(iv);
            const char *typeC = ivar_getTypeEncoding(iv);
            if (!nameC || !typeC || typeC[0] != '@') continue;

            NSString *name = [NSString stringWithUTF8String:nameC] ?: @"?";
            NSString *lower = name.lowercaseString;
            BOOL interesting = [lower containsString:@"section"] ||
                               [lower containsString:@"item"] ||
                               [lower containsString:@"row"] ||
                               [lower containsString:@"menu"] ||
                               [lower containsString:@"table"] ||
                               [lower containsString:@"debug"] ||
                               [lower containsString:@"data"];
            if (!interesting) continue;

            id value = nil;
            @try { value = object_getIvar(owner, iv); } @catch (__unused NSException *ex) {}
            WAGRDMPreview(value, NSStringFromClass([owner class]), [NSString stringWithFormat:@"%@ ivar %@", stage ?: @"stage", name]);
        }
        free(ivars);
    }
}

static void WAGRDebugMenuInstrumentationDumpSelectors(id owner, NSString *stage) {
    if (!owner) return;
    for (NSString *name in WAGRDMObjectSelectors()) {
        SEL sel = NSSelectorFromString(name);
        Method m = class_getInstanceMethod([owner class], sel);
        if (!m || method_getNumberOfArguments(m) != 2 || !WAGRDMMethodReturns(m, '@')) continue;
        id value = nil;
        @try { value = ((id (*)(id, SEL))objc_msgSend)(owner, sel); }
        @catch (NSException *ex) {
            WAGRLogAppendF(@"[DebugMenuSpy] dump %@.%@ threw %@: %@", NSStringFromClass([owner class]), name, ex.name, ex.reason);
            continue;
        }
        WAGRDMPreview(value, NSStringFromClass([owner class]), [NSString stringWithFormat:@"%@ selector %@", stage ?: @"stage", name]);
    }
}

static void WAGRDebugMenuInstrumentationDumpState(id owner, NSString *stage) {
    if (!owner) return;
    WAGRLogAppendF(@"[DebugMenuSpy] dump state owner=%@ stage=%@",
                   NSStringFromClass([owner class]), stage ?: @"?");
    WAGRDebugMenuInstrumentationInstallAssemblyHooksForClass([owner class], stage ?: @"dump");
    WAGRDebugMenuInstrumentationInstallObjectHooksForClass([owner class], stage ?: @"dump");
    WAGRDebugMenuInstrumentationDumpSelectors(owner, stage ?: @"dump");
    WAGRDebugMenuInstrumentationDumpIvars(owner, stage ?: @"dump");
}

static void WAGRDebugMenuInstrumentationInspectVC(id vc, NSString *stage) {
    if (![vc isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)vc;
    WAGRDebugMenuInstrumentationInstallTableHooksForClass([controller class], stage ?: @"vc");

    NSArray<UITableView *> *tables = WAGRDMFindTables(controller.view);
    WAGRLogAppendF(@"[DebugMenuSpy] inspect %@ stage=%@ tables=%lu title='%@'",
                   NSStringFromClass([controller class]), stage ?: @"?", (unsigned long)tables.count, controller.title ?: @"");

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
            NSInteger sections = [ds respondsToSelector:@selector(numberOfSectionsInTableView:)]
                ? ((NSInteger (*)(id, SEL, id))objc_msgSend)(ds, @selector(numberOfSectionsInTableView:), table)
                : 1;
            WAGRLogAppendF(@"[DebugMenuSpy] snapshot table sections=%ld", (long)sections);
            for (NSInteger s = 0; s < MIN((NSInteger)24, sections); s++) {
                NSInteger rows = [ds respondsToSelector:@selector(tableView:numberOfRowsInSection:)]
                    ? ((NSInteger (*)(id, SEL, id, NSInteger))objc_msgSend)(ds, @selector(tableView:numberOfRowsInSection:), table, s)
                    : 0;
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
        WAGRDMInstall(debugCls, NSSelectorFromString(@"viewDidLoad"), (IMP)hookDMViewDidLoad, @"void");
        WAGRDMInstall(debugCls, NSSelectorFromString(@"viewWillAppear:"), (IMP)hookDMViewWillAppear, @"voidBool");
        WAGRDMInstall(debugCls, NSSelectorFromString(@"viewDidAppear:"), (IMP)hookDMViewDidAppear, @"voidBool");
        WAGRDebugMenuInstrumentationInstallAssemblyHooksForClass(debugCls, @"base-debug-vc");
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
