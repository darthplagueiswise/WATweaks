#import "WAGRABPropsRootVC.h"
#import "WAGRABPropsBrowserVC.h"
#import "WAGRABPropsSnapshotVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

extern BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);
extern NSString *WAGRCurrentUserContextDiagnostic(void);
extern NSString *WAGRDebugMenuLauncherDiagnosticText(void);
extern NSString *WAGRDebugMenuInstrumentationDiagnosticText(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern id WAGRCurrentUserContext(void);
extern void WAGRRememberUserContext(id ctx, NSString *source);
extern void WAGRGateHooksEnsureInstalled(void);

#pragma mark - Live userContext recovery for native ABProps

static const char *WAGRABRootSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABRootMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABRootSkipQualifiers(raw)[0] == '@';
}

static id WAGRABRootCallObjectNoArg(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABRootMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABRootCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRABRootMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRABRootLooksLikeUserContext(id object) {
    if (!object) return NO;
    NSString *className = NSStringFromClass([object class]) ?: @"";
    if ([className containsString:@"UserContext"] ||
        [className isEqualToString:@"WAContext"] ||
        [className containsString:@"WAContext"] ||
        [className containsString:@"ContextMain"]) return YES;

    // Current WhatsApp build exposes the exact ABProps request-manager accessor
    // on its live WAContext. This is a stronger signal than a name heuristic.
    if ([object respondsToSelector:NSSelectorFromString(@"xmppConnectionABPropsRequestManager")]) return YES;
    if ([object respondsToSelector:NSSelectorFromString(@"abProperties")]) return YES;
    if ([object respondsToSelector:NSSelectorFromString(@"debugPropOverrides")]) return YES;
    return NO;
}

static id WAGRABRootProbeObject(id object) {
    if (!object) return nil;
    if (WAGRABRootLooksLikeUserContext(object)) return object;

    for (NSString *selectorName in @[
        @"userContext", @"wa_userContext", @"currentUserContext",
        @"sharedUserContext", @"mainContext", @"sharedContext",
        @"currentContext", @"context", @"waContext"
    ]) {
        id candidate = WAGRABRootCallObjectNoArg(object, selectorName);
        if (WAGRABRootLooksLikeUserContext(candidate)) return candidate;
    }

    for (NSString *ivarName in @[@"_userContext", @"userContext", @"_context", @"_waContext"]) {
        Ivar ivar = class_getInstanceVariable([object class], ivarName.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || WAGRABRootSkipQualifiers(type)[0] != '@') continue;
        id candidate = nil;
        @try { candidate = object_getIvar(object, ivar); }
        @catch (__unused NSException *exception) { candidate = nil; }
        if (WAGRABRootLooksLikeUserContext(candidate)) return candidate;
    }

    @try {
        id candidate = [object valueForKey:@"userContext"];
        if (WAGRABRootLooksLikeUserContext(candidate)) return candidate;
    } @catch (__unused NSException *exception) {}
    return nil;
}

static id WAGRABRootFindInControllerTree(UIViewController *controller, NSInteger depth) {
    if (!controller || depth > 24) return nil;
    id context = WAGRABRootProbeObject(controller);
    if (context) return context;

    for (UIViewController *child in controller.childViewControllers) {
        context = WAGRABRootFindInControllerTree(child, depth + 1);
        if (context) return context;
    }
    if (controller.presentedViewController) {
        context = WAGRABRootFindInControllerTree(controller.presentedViewController, depth + 1);
        if (context) return context;
    }
    return nil;
}

static id WAGRABRootResolveUserContext(void) {
    id cached = WAGRCurrentUserContext();
    if (cached) return cached;

    // The WATweaks sheet is presented over WhatsApp's own Settings hierarchy.
    // Walk both the underlying and presented controller trees before guessing any
    // singleton. wagr_findUserContextAnywhere in the native launcher uses the same
    // source, but this keeps ABProps Fetch independent of opening Developer first.
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        id context = WAGRABRootFindInControllerTree(window.rootViewController, 0);
        if (context) {
            WAGRRememberUserContext(context, @"ABPropsRoot controller tree");
            return context;
        }
    }

    id appDelegate = (id)UIApplication.sharedApplication.delegate;
    id context = WAGRABRootProbeObject(appDelegate);
    if (context) {
        WAGRRememberUserContext(context, @"ABPropsRoot app delegate");
        return context;
    }

    // Deterministic class roots are fallback-only and every returned object is
    // validated as a WhatsApp user context before it is cached.
    for (NSString *className in @[@"WAContext", @"WAContextMain"]) {
        Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
        if (!cls) continue;
        for (NSString *selectorName in @[
            @"shared", @"sharedInstance", @"current", @"currentContext",
            @"mainContext", @"defaultContext", @"context", @"waContext"
        ]) {
            id candidate = WAGRABRootCallClassObjectNoArg(cls, selectorName);
            context = WAGRABRootProbeObject(candidate);
            if (!context) continue;
            WAGRRememberUserContext(context,
                [NSString stringWithFormat:@"ABPropsRoot +%@.%@", className, selectorName]);
            return context;
        }
    }
    return nil;
}

static id WAGRABRootPrimeUserContext(void) {
    id context = WAGRABRootResolveUserContext();
    WAGRLogAppendF(@"[ABProps][Context] preflight=%@",
                   context ? NSStringFromClass([context class]) : @"nil");
    return context;
}

typedef NS_ENUM(NSInteger, WAGRABPropsAction) {
    WAGRABPropsActionNativeSnapshot = 0,
    WAGRABPropsActionLiveBrowser,
    WAGRABPropsActionRuntimeFamilies,
    WAGRABPropsActionPrivateExperimentation,
    WAGRABPropsActionContextDiagnostic,
    WAGRABPropsActionLogs,
};

@interface WAGRABPropsRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *icon;
@property(nonatomic, copy) NSString *accentKey;
@property(nonatomic, assign) WAGRABPropsAction action;
+ (instancetype)rowWithTitle:(NSString *)title
                      detail:(NSString *)detail
                        icon:(NSString *)icon
                   accentKey:(NSString *)accentKey
                      action:(WAGRABPropsAction)action;
@end

@implementation WAGRABPropsRow
+ (instancetype)rowWithTitle:(NSString *)title
                      detail:(NSString *)detail
                        icon:(NSString *)icon
                   accentKey:(NSString *)accentKey
                      action:(WAGRABPropsAction)action {
    WAGRABPropsRow *row = [self new];
    row.title = title ?: @"";
    row.detail = detail ?: @"";
    row.icon = icon ?: @"circle";
    row.accentKey = accentKey ?: title ?: @"runtime";
    row.action = action;
    return row;
}
@end

@interface WAGRABPropsRootVC ()
@property(nonatomic, copy) NSArray<NSArray<WAGRABPropsRow *> *> *sections;
@end

@implementation WAGRABPropsRootVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"AB Props";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.sections = [self buildSections];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar"
        style:UIBarButtonItemStyleDone
        target:self
        action:@selector(applyOverrides)];
    (void)WAGRABRootPrimeUserContext();
}

- (NSArray<NSArray<WAGRABPropsRow *> *> *)buildSections {
    NSArray<WAGRABPropsRow *> *runtime = @[
        [WAGRABPropsRow rowWithTitle:@"Snapshot nativo · Fetch / Export"
                              detail:@"Lê todas as ABProps account-scoped do gabp.*p em group.net.whatsapp.WhatsApp.shared, dispara o refresh nativo e exporta o snapshot completo com tradução WAMCEvaluation."
                                icon:@"arrow.triangle.2.circlepath"
                           accentKey:@"waab-native-snapshot"
                              action:WAGRABPropsActionNativeSnapshot],
        [WAGRABPropsRow rowWithTitle:@"WAABProperties ao vivo"
                              detail:@"Enumera agora os getters anexados a WAABProperties e providers concretos; não usa catálogo JSON."
                                icon:@"switch.2"
                           accentKey:@"waab-live"
                              action:WAGRABPropsActionLiveBrowser],
        [WAGRABPropsRow rowWithTitle:@"Todas as famílias carregadas"
                              detail:@"Reconstrói categorias e subcategorias das imagens, classes, selectors e ABIs presentes neste processo."
                                icon:@"square.grid.2x2.fill"
                           accentKey:@"runtime-live"
                              action:WAGRABPropsActionRuntimeFamilies],
        [WAGRABPropsRow rowWithTitle:@"Fetch Experiments / Private Experimentation"
                              detail:@"Abre o fluxo Swift nativo com o userContext capturado pelo Developer Menu."
                                icon:@"arrow.down.doc.fill"
                           accentKey:@"private-experimentation"
                              action:WAGRABPropsActionPrivateExperimentation],
    ];

    NSArray<WAGRABPropsRow *> *diagnostics = @[
        [WAGRABPropsRow rowWithTitle:@"Context / PreFlight Inspector"
                              detail:@"UserContext, launcher, DebugMenu instrumentation, GateHooks, cache ABProps nativo e estatísticas do último scan vivo."
                                icon:@"checklist.checked"
                           accentKey:@"context"
                              action:WAGRABPropsActionContextDiagnostic],
        [WAGRABPropsRow rowWithTitle:@"WATweaks Log"
                              detail:@"Logs desta sessão, incluindo resolução de objetos WAAB, fetch nativo, AppGroup e scans do runtime."
                                icon:@"doc.text.magnifyingglass"
                           accentKey:@"log"
                              action:WAGRABPropsActionLogs],
    ];

    return @[runtime, diagnostics];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return 0;
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"ABProps nativas / Runtime" : @"Diagnóstico";
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return @"O snapshot nativo usa o payload account-scoped gabp.*p que o próprio WhatsApp atualiza após o IQ ABPROPS. WAABProperties ao vivo é a camada de getters/hook. MobileConfig continua sendo um sistema relacionado, mas separado.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WAGRABPropsRow *row = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRABPropsRootLiveCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"WAGRABPropsRootLiveCell"];
    }
    WAGRMenuApplyCellStyle(cell, indexPath.row, row.accentKey);
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = WAGRMenuSymbol(row.icon, nil);
    cell.imageView.tintColor = WAGRMenuAccentForKey(row.accentKey, indexPath.row);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGRABPropsRow *row = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    switch (row.action) {
        case WAGRABPropsActionNativeSnapshot: {
            id context = WAGRABRootPrimeUserContext();
            WAGRABPropsSnapshotVC *controller = [[WAGRABPropsSnapshotVC alloc]
                initWithUserContext:context];
            [self.navigationController pushViewController:controller animated:YES];
            return;
        }
        case WAGRABPropsActionLiveBrowser: {
            id context = WAGRABRootPrimeUserContext();
            WAGRABPropsBrowserVC *browser = [[WAGRABPropsBrowserVC alloc]
                initWithUserContext:context];
            [self.navigationController pushViewController:browser animated:YES];
            return;
        }
        case WAGRABPropsActionRuntimeFamilies:
            [self.navigationController pushViewController:[WAGRRuntimeGatesVC new]
                                                 animated:YES];
            return;
        case WAGRABPropsActionPrivateExperimentation: {
            NSError *error = nil;
            if (!WAGRLaunchPrivateExperimentationDebug(self, &error)) {
                [self showAlert:@"Private Experimentation"
                        message:error.localizedDescription ?: @"Não foi possível abrir."];
            }
            return;
        }
        case WAGRABPropsActionContextDiagnostic:
            [self showContextDiagnostic];
            return;
        case WAGRABPropsActionLogs:
            [self.navigationController pushViewController:[WAGRLogViewController new]
                                                 animated:YES];
            return;
    }
}

- (void)applyOverrides {
    WAGRGateHooksEnsureInstalled();
    [self showAlert:@"AB Props"
            message:[NSString stringWithFormat:@"Overrides persistidos: %lu",
                     (unsigned long)WAGRGateAllOverrides().count]];
}

- (void)showContextDiagnostic {
    (void)WAGRABRootPrimeUserContext();
    NSDictionary *stats = WAGRABPropsCatalogStats();
    NSError *snapshotError = nil;
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(&snapshotError);
    NSString *native = snapshot
        ? [NSString stringWithFormat:@"Native cache: %lu props · %@ · %@",
           (unsigned long)snapshot.numericPropCount, snapshot.payloadKey ?: @"?",
           snapshot.fingerprint ?: @"?"]
        : [NSString stringWithFormat:@"Native cache: %@",
           snapshotError.localizedDescription ?: WAGRABPropsNativeDiagnosticText()];
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n[WAAB live stats]\n%@",
                         WAGRCurrentUserContextDiagnostic() ?: @"UserContext: n/a",
                         WAGRDebugMenuLauncherDiagnosticText() ?: @"Launcher: n/a",
                         WAGRDebugMenuInstrumentationDiagnosticText() ?: @"DebugMenuSpy: n/a",
                         WAGRGateHooksDiagnostic() ?: @"GateHooks: n/a",
                         native,
                         stats.count ? stats.description : @"nenhum scan executado nesta sessão"];
    [self showAlert:@"Context / PreFlight" message:message];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title ?: @"AB Props"
        message:message ?: @""
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = message ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
