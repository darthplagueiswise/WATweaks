// WAGRDebugMenuInstrumentation.xm
// Diagnostic owner for WhatsApp's native WADebugViewController menu assembly.
// New WhatsApp(11) target: the useful choke point is -createSections, not only
// tableView datasource callbacks. It no longer mutates native section counts; only observes and adds a back button.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../Runtime/WAGRLog.h"
#import "../Runtime/WAGRGateRegistry.h"
#import "../Menu/WAGRRuntimeGatesVC.h"
#import "../Menu/WAGRGateCategoryVC.h"
#import "../Menu/WAGRLogViewController.h"

typedef void      (*WAGRDMVoidIMP)(id, SEL);
typedef void      (*WAGRDMVoidBoolIMP)(id, SEL, BOOL);
typedef id        (*WAGRDMObjectIMP)(id, SEL);
typedef NSInteger (*WAGRDMSectionsIMP)(id, SEL, id);
typedef NSInteger (*WAGRDMRowsIMP)(id, SEL, id, NSInteger);
typedef id        (*WAGRDMCellIMP)(id, SEL, id, id);
typedef id        (*WAGRDMTitleIMP)(id, SEL, id, NSInteger);
typedef void      (*WAGRDMDidSelectIMP)(id, SEL, id, id);

static NSMutableDictionary<NSString *, NSValue *> *gWAGRDMOrig;
static NSMutableSet<NSString *> *gWAGRDMInstalled;
static NSMutableSet<NSString *> *gWAGRDMObservedClasses;
static BOOL gWAGRDMBaseInstalled = NO;
static IMP WAGRDMOrig(Class cls, SEL sel, NSString *kind);


extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);
extern "C" NSString *WAGRCurrentUserContextDiagnostic(void);
extern "C" NSString *WAGRDebugMenuLauncherDiagnosticText(void);
extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void);
extern "C" NSString *WAGRGateHooksDiagnostic(void);
extern "C" void WAGRGateHooksEnsureInstalled(void);

@interface WAGRDebugMenuBackTarget : NSObject
@property(nonatomic, weak) UIViewController *viewController;
- (void)wagrBack:(id)sender;
@end

@implementation WAGRDebugMenuBackTarget
- (void)wagrBack:(__unused id)sender {
    UIViewController *vc = self.viewController;
    if (!vc) return;
    UINavigationController *nav = vc.navigationController;
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        return;
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (nav.presentingViewController) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    }
}
@end

static const char *kWAGRDebugBackTargetKey = "watweaks.debug.back.target";
static const NSInteger kWAGRDMExtraSectionRows = 5;

static BOOL WAGRDMIsNativeDebugClass(Class cls) {
    NSString *name = cls ? NSStringFromClass(cls) : @"";
    return [name isEqualToString:@"WADebugViewController"];
}

static BOOL WAGRDMIsNativeDebugVC(id self) {
    return self ? WAGRDMIsNativeDebugClass([self class]) : NO;
}

static NSArray<NSString *> *WAGRDMExtraTitles(void) {
    return @[ @"Runtime Gates / AB Flags",
              @"WAAB Feature Keys",
              @"Private Experimentation",
              @"Context / PreFlight Inspector",
              @"Log Controls" ];
}

static NSArray<NSString *> *WAGRDMExtraSubtitles(void) {
    return @[ @"Abre a tela de categorias com toggles persistentes.",
              @"Vai direto para WAAB Properties / AB feature flags.",
              @"Abre o fluxo Swift PrivateExperimentation com o userContext real.",
              @"Mostra cache de userContext, launcher e diagnósticos de hooks.",
              @"Abre o buffer de logs WATweaks desta sessão." ];
}

static NSInteger WAGRDMOriginalSectionCount(id self, id tableView) {
    WAGRDMSectionsIMP orig = (WAGRDMSectionsIMP)WAGRDMOrig([self class], NSSelectorFromString(@"numberOfSectionsInTableView:"), @"sections");
    if (orig) return orig(self, NSSelectorFromString(@"numberOfSectionsInTableView:"), tableView);
    SEL sectionsSel = NSSelectorFromString(@"sections");
    if ([self respondsToSelector:sectionsSel]) {
        id sections = nil;
        @try { sections = ((id (*)(id, SEL))objc_msgSend)(self, sectionsSel); } @catch (__unused NSException *ex) { sections = nil; }
        if ([sections respondsToSelector:@selector(count)]) return (NSInteger)[sections count];
    }
    return 1;
}

static BOOL WAGRDMIsExtraSection(id self, id tableView, NSInteger section) {
    // Disabled deliberately: mutating WADebugViewController's datasource section
    // count can desync WhatsApp's private WATableSection cache and crash the
    // native Developer menu. Keep this instrumentation observational.
    (void)self; (void)tableView; (void)section;
    return NO;
}

static void WAGRDMEnsureBackButton(id owner) {
    if (![owner isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)owner;
    if (vc.navigationItem.leftBarButtonItem) return;
    WAGRDebugMenuBackTarget *target = [WAGRDebugMenuBackTarget new];
    target.viewController = vc;
    objc_setAssociatedObject(vc, kWAGRDebugBackTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"Voltar"
                                                             style:UIBarButtonItemStylePlain
                                                            target:target
                                                            action:@selector(wagrBack:)];
    back.accessibilityIdentifier = @"WATweaksDebugBackButton";
    vc.navigationItem.leftBarButtonItem = back;
}

static UIViewController *WAGRDMTopControllerFrom(id owner) {
    if ([owner isKindOfClass:UIViewController.class]) return (UIViewController *)owner;
    UIViewController *top = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (win.isKeyWindow) { top = win.rootViewController; break; }
    }
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).visibleViewController;
    if ([top isKindOfClass:UITabBarController.class]) top = ((UITabBarController *)top).selectedViewController;
    return top;
}

static void WAGRDMPushOrPresentFrom(id owner, UIViewController *vc) {
    if (!vc) return;
    UIViewController *top = WAGRDMTopControllerFrom(owner);
    UINavigationController *nav = top.navigationController;
    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:vc];
        wrap.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:wrap animated:YES completion:nil];
    }
}

static void WAGRDMShowAlert(id owner, NSString *title, NSString *message) {
    UIViewController *top = WAGRDMTopControllerFrom(owner);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"WATweaks"
                                                                   message:message ?: @""
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

static UITableViewCell *WAGRDMExtraCell(id tableView, NSInteger row) {
    UITableViewCell *cell = nil;
    if ([tableView respondsToSelector:@selector(dequeueReusableCellWithIdentifier:)]) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"WATweaksDebugExtraCell"];
    }
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WATweaksDebugExtraCell"];
    NSArray<NSString *> *titles = WAGRDMExtraTitles();
    NSArray<NSString *> *subs = WAGRDMExtraSubtitles();
    if (row >= 0 && row < (NSInteger)titles.count) {
        cell.textLabel.text = titles[(NSUInteger)row];
        cell.detailTextLabel.text = subs[(NSUInteger)row];
    } else {
        cell.textLabel.text = @"WATweaks";
        cell.detailTextLabel.text = @"";
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"WATweaksDebugExtraRow%ld", (long)row];
    return cell;
}

static void WAGRDMOpenExtraRow(id owner, NSInteger row) {
    WAGRLogAppendF(@"[DebugMenuSpy] WATweaks extra row selected=%ld", (long)row);
    WAGRGateHooksEnsureInstalled();
    if (row == 0) {
        WAGRDMPushOrPresentFrom(owner, [WAGRRuntimeGatesVC new]);
        return;
    }
    if (row == 1) {
        WAGRGateProvider *p = [WAGRGateRegistry providerWithID:@"waab"];
        if (p) WAGRDMPushOrPresentFrom(owner, [[WAGRGateCategoryVC alloc] initWithProvider:p]);
        else WAGRDMShowAlert(owner, @"WAAB Feature Keys", @"Provider WAAB não encontrado no registry.");
        return;
    }
    if (row == 2) {
        NSError *err = nil;
        BOOL ok = WAGRLaunchPrivateExperimentationDebug(WAGRDMTopControllerFrom(owner), &err);
        if (!ok) WAGRDMShowAlert(owner, @"Private Experimentation", err.localizedDescription ?: @"Não foi possível abrir.");
        return;
    }
    if (row == 3) {
        NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@",
                         WAGRCurrentUserContextDiagnostic() ?: @"UserContext: n/a",
                         WAGRDebugMenuLauncherDiagnosticText() ?: @"Launcher: n/a",
                         WAGRDebugMenuInstrumentationDiagnosticText() ?: @"DebugMenuSpy: n/a",
                         WAGRGateHooksDiagnostic() ?: @"GateHooks: n/a"];
        WAGRDMShowAlert(owner, @"Context / PreFlight", msg);
        return;
    }
    if (row == 4) {
        WAGRDMPushOrPresentFrom(owner, [WAGRLogViewController new]);
        return;
    }
}

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
    if ([gWAGRDMInstalled containsObject:key]) return NO;

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


static void WAGRDMReloadTablesForOwner(id owner) {
    if (![owner isKindOfClass:UIViewController.class]) return;
    for (UITableView *table in WAGRDMFindTables(((UIViewController *)owner).view)) {
        [table reloadData];
    }
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

static BOOL WAGRDMShouldLogStable(NSString *key, NSString *value) {
    static NSMutableDictionary<NSString *, NSString *> *last = nil;
    if (!last) last = [NSMutableDictionary dictionary];
    NSString *old = last[key];
    if (old && [old isEqualToString:value ?: @"nil"]) return NO;
    last[key] = value ?: @"nil";
    return YES;
}

static NSInteger hookDMSections(id self, SEL _cmd, id tableView) {
    WAGRDMSectionsIMP orig = (WAGRDMSectionsIMP)WAGRDMOrig([self class], _cmd, @"sections");
    NSInteger native = orig ? orig(self, _cmd, tableView) : 1;
    NSString *key = [NSString stringWithFormat:@"sections|%@", NSStringFromClass([self class])];
    NSString *val = [NSString stringWithFormat:@"%ld", (long)native];
    if (WAGRDMShouldLogStable(key, val)) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@ numberOfSections -> %ld", NSStringFromClass([self class]), (long)native);
    }
    return native;
}

static NSInteger hookDMRows(id self, SEL _cmd, id tableView, NSInteger section) {
    if (WAGRDMIsExtraSection(self, tableView, section)) return kWAGRDMExtraSectionRows;
    WAGRDMRowsIMP orig = (WAGRDMRowsIMP)WAGRDMOrig([self class], _cmd, @"rows");
    NSInteger ret = orig ? orig(self, _cmd, tableView, section) : 0;
    NSString *key = [NSString stringWithFormat:@"rows|%@|%ld", NSStringFromClass([self class]), (long)section];
    NSString *val = [NSString stringWithFormat:@"%ld", (long)ret];
    if (WAGRDMShouldLogStable(key, val)) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@ rows section=%ld -> %ld", NSStringFromClass([self class]), (long)section, (long)ret);
    }
    return ret;
}

static id hookDMCell(id self, SEL _cmd, id tableView, id indexPath) {
    if ([indexPath isKindOfClass:NSIndexPath.class] && WAGRDMIsExtraSection(self, tableView, [(NSIndexPath *)indexPath section])) {
        return WAGRDMExtraCell(tableView, [(NSIndexPath *)indexPath row]);
    }
    WAGRDMCellIMP orig = (WAGRDMCellIMP)WAGRDMOrig([self class], _cmd, @"cell");
    id ret = orig ? orig(self, _cmd, tableView, indexPath) : nil;
    NSString *key = [NSString stringWithFormat:@"cell|%@|%@", NSStringFromClass([self class]), WAGRDMIndexPath(indexPath)];
    NSString *val = WAGRDMCellText(ret);
    if (WAGRDMShouldLogStable(key, val)) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@ cell %@ -> %@", NSStringFromClass([self class]), WAGRDMIndexPath(indexPath), val);
    }
    return ret;
}

static id hookDMHeader(id self, SEL _cmd, id tableView, NSInteger section) {
    if (WAGRDMIsExtraSection(self, tableView, section)) return @"WATweaks";
    WAGRDMTitleIMP orig = (WAGRDMTitleIMP)WAGRDMOrig([self class], _cmd, @"header");
    id ret = orig ? orig(self, _cmd, tableView, section) : nil;
    NSString *key = [NSString stringWithFormat:@"header|%@|%ld", NSStringFromClass([self class]), (long)section];
    NSString *val = [ret description] ?: @"nil";
    if (WAGRDMShouldLogStable(key, val)) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@ header section=%ld -> %@", NSStringFromClass([self class]), (long)section, ret ?: @"nil");
    }
    return ret;
}

static id hookDMFooter(id self, SEL _cmd, id tableView, NSInteger section) {
    if (WAGRDMIsExtraSection(self, tableView, section)) return @"Atalhos estáveis do WATweaks sem mexer em WATableSection/WATableRow nativos.";
    WAGRDMTitleIMP orig = (WAGRDMTitleIMP)WAGRDMOrig([self class], _cmd, @"footer");
    id ret = orig ? orig(self, _cmd, tableView, section) : nil;
    NSString *key = [NSString stringWithFormat:@"footer|%@|%ld", NSStringFromClass([self class]), (long)section];
    NSString *val = [ret description] ?: @"nil";
    if (WAGRDMShouldLogStable(key, val)) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@ footer section=%ld -> %@", NSStringFromClass([self class]), (long)section, ret ?: @"nil");
    }
    return ret;
}

static void hookDMDidSelect(id self, SEL _cmd, id tableView, id indexPath) {
    if ([indexPath isKindOfClass:NSIndexPath.class] && WAGRDMIsExtraSection(self, tableView, [(NSIndexPath *)indexPath section])) {
        if ([tableView respondsToSelector:@selector(deselectRowAtIndexPath:animated:)]) {
            [(UITableView *)tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
        WAGRDMOpenExtraRow(self, [(NSIndexPath *)indexPath row]);
        return;
    }
    WAGRDMDidSelectIMP orig = (WAGRDMDidSelectIMP)WAGRDMOrig([self class], _cmd, @"didSelect");
    if (orig) orig(self, _cmd, tableView, indexPath);
}

static id hookDMObject(id self, SEL _cmd) {
    WAGRDMObjectIMP orig = (WAGRDMObjectIMP)WAGRDMOrig([self class], _cmd, @"object");
    id ret = nil;
    @try { ret = orig ? orig(self, _cmd) : nil; }
    @catch (NSException *ex) {
        WAGRLogAppendF(@"[DebugMenuSpy] %@.%@ threw %@: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), ex.name, ex.reason);
    }
    NSString *logKey = [NSString stringWithFormat:@"object|%@|%@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    NSString *logVal = WAGRDMShort(ret);
    if (WAGRDMShouldLogStable(logKey, logVal)) {
        WAGRDMPreview(ret, NSStringFromClass([self class]), NSStringFromSelector(_cmd));
    }
    if ([ret isKindOfClass:UIViewController.class]) WAGRDebugMenuInstrumentationInspectVC(ret, NSStringFromSelector(_cmd));
    return ret;
}

static void hookDMViewDidLoad(id self, SEL _cmd) {
    WAGRDMVoidIMP orig = (WAGRDMVoidIMP)WAGRDMOrig([self class], _cmd, @"void");
    if (orig) orig(self, _cmd);
    if (WAGRDMIsNativeDebugVC(self)) { WAGRDMEnsureBackButton(self); WAGRDMReloadTablesForOwner(self); }
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewDidLoad", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"viewDidLoad");
    WAGRDebugMenuInstrumentationInspectVC(self, @"viewDidLoad");
}

static void hookDMViewWillAppear(id self, SEL _cmd, BOOL animated) {
    WAGRDMVoidBoolIMP orig = (WAGRDMVoidBoolIMP)WAGRDMOrig([self class], _cmd, @"voidBool");
    if (orig) orig(self, _cmd, animated);
    if (WAGRDMIsNativeDebugVC(self)) { WAGRDMEnsureBackButton(self); WAGRDMReloadTablesForOwner(self); }
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewWillAppear", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"viewWillAppear");
    WAGRDebugMenuInstrumentationInspectVC(self, @"viewWillAppear");
}

static void hookDMViewDidAppear(id self, SEL _cmd, BOOL animated) {
    WAGRDMVoidBoolIMP orig = (WAGRDMVoidBoolIMP)WAGRDMOrig([self class], _cmd, @"voidBool");
    if (orig) orig(self, _cmd, animated);
    if (WAGRDMIsNativeDebugVC(self)) { WAGRDMEnsureBackButton(self); WAGRDMReloadTablesForOwner(self); }
    WAGRLogAppendF(@"[DebugMenuSpy] %@ viewDidAppear", NSStringFromClass([self class]));
    WAGRDebugMenuInstrumentationDumpState(self, @"viewDidAppear");
    WAGRDebugMenuInstrumentationInspectVC(self, @"viewDidAppear");
}

static void hookDMSetUpTableView(id self, SEL _cmd) {
    WAGRDMVoidIMP orig = (WAGRDMVoidIMP)WAGRDMOrig([self class], _cmd, @"setUpTableView");
    WAGRLogAppendF(@"[DebugMenuSpy] %@ setUpTableView before", NSStringFromClass([self class]));
    if (orig) orig(self, _cmd);
    if (WAGRDMIsNativeDebugVC(self)) { WAGRDMEnsureBackButton(self); WAGRDMReloadTablesForOwner(self); }
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

    NSUInteger installed = 0;
    SEL setupSel = NSSelectorFromString(@"setUpTableView");
    Method setup = class_getInstanceMethod(cls, setupSel);
    if (setup && method_getNumberOfArguments(setup) == 2 && WAGRDMMethodReturns(setup, 'v')) {
        installed += WAGRDMInstall(cls, setupSel, (IMP)hookDMSetUpTableView, @"setUpTableView") ? 1 : 0;
    }

    SEL createSel = NSSelectorFromString(@"createSections");
    Method create = class_getInstanceMethod(cls, createSel);
    if (create && method_getNumberOfArguments(create) == 2) {
        if (WAGRDMMethodReturns(create, 'v')) {
            installed += WAGRDMInstall(cls, createSel, (IMP)hookDMCreateSectionsVoid, @"createSectionsVoid") ? 1 : 0;
        } else if (WAGRDMMethodReturns(create, '@')) {
            installed += WAGRDMInstall(cls, createSel, (IMP)hookDMCreateSectionsObject, @"createSectionsObject") ? 1 : 0;
        } else {
            char ret[32] = {0};
            method_getReturnType(create, ret, sizeof(ret));
            NSString *skipKey = [NSString stringWithFormat:@"skip-create|%@", NSStringFromClass(cls)];
            NSString *skipVal = [NSString stringWithUTF8String:ret] ?: @"?";
            if (WAGRDMShouldLogStable(skipKey, skipVal)) {
                WAGRLogAppendF(@"[DebugMenuSpy] skipped %@.createSections unsupported return='%s'", NSStringFromClass(cls), ret);
            }
        }
    }

    if (installed) {
        WAGRLogAppendF(@"[DebugMenuSpy] assembly probes installed class=%@ source=%@ count=%lu setup=%@ create=%@",
                       NSStringFromClass(cls), source ?: @"?", (unsigned long)installed,
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
    BOOL didSelectHooked = WAGRDMInstall(cls, NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:"), (IMP)hookDMDidSelect, @"didSelect");
    if (!didSelectHooked && WAGRDMIsNativeDebugClass(cls)) {
        SEL didSel = NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:");
        if (class_addMethod(cls, didSel, (IMP)hookDMDidSelect, "v@:@@")) {
            didSelectHooked = YES;
            WAGRLogAppendF(@"[DebugMenuSpy] added %@.%@ kind=didSelect", NSStringFromClass(cls), NSStringFromSelector(didSel));
        }
    }
    tableHooks += didSelectHooked ? 1 : 0;

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

    NSString *ensureVal = [NSString stringWithFormat:@"debugVC=%@ provider=%@ totalHooks=%lu",
                           debugCls ? @"YES" : @"NO",
                           providerCls ? @"YES" : @"NO",
                           (unsigned long)gWAGRDMInstalled.count];
    if (WAGRDMShouldLogStable(@"ensure-installed", ensureVal)) {
        WAGRLogAppendF(@"[DebugMenuSpy] ensure installed %@", ensureVal);
    }
}

extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"DebugMenuSpy baseInstalled=%@\ninstalled hooks=%lu\nobserved classes=%@",
            gWAGRDMBaseInstalled ? @"YES" : @"NO",
            (unsigned long)gWAGRDMInstalled.count,
            [[gWAGRDMObservedClasses allObjects] componentsJoinedByString:@", "] ?: @""];
}

static void WAGRDebugMenuInstrumentationScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WAGRDebugMenuInstrumentationEnsureInstalled();
    });
}

__attribute__((constructor))
static void WAGRDebugMenuInstrumentationCtor(void) {
    @autoreleasepool {
        WAGRDebugMenuInstrumentationEnsureInstalled();
        WAGRDebugMenuInstrumentationScheduleRetry(0.2);
        WAGRDebugMenuInstrumentationScheduleRetry(1.0);
        WAGRDebugMenuInstrumentationScheduleRetry(3.0);
    }
}
