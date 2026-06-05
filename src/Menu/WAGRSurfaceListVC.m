#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "WAGRSurfaceListVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRSecretMenusVC.h"
#import "WAGRLogViewController.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRABPropsRootVC.h"
#import "../WAGramPrefix.h"
#import "../WAUtils.h"
#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRGateStore.h"
#import "WAGRMenuTheme.h"

extern BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);
extern BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);
extern NSString *WAGRHookRouterDiagnostic(void);
extern NSString *WAGRLGDiagnosticText(void);
extern NSString *WAGRDogfoodDiagnosticText(void);
extern NSString *WAKeychainAccessGroupDiagnostic(void);
extern NSUInteger WAGRReinstallPersistedHooks(void);

static UIViewController *WAGRTopController(void) {
    UIViewController *c = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { c = w.rootViewController; break; }
        }
        if (c) break;
    }
    UIViewController *p = nil;
    while (c && c != p) {
        p = c;
        if (c.presentedViewController) { c = c.presentedViewController; continue; }
        if ([c isKindOfClass:UINavigationController.class]) {
            UIViewController *v = ((UINavigationController *)c).visibleViewController;
            if (v && v != c) { c = v; continue; }
        }
        if ([c isKindOfClass:UITabBarController.class]) {
            UIViewController *v = ((UITabBarController *)c).selectedViewController;
            if (v && v != c) { c = v; continue; }
        }
        break;
    }
    return c;
}

static void WAGRAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"WATweaks" message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused id _) { UIPasteboard.generalPasteboard.string = message ?: @""; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [WAGRTopController() presentViewController:a animated:YES completion:nil];
    });
}

typedef NS_ENUM(NSInteger, WAGRRootSection) {
    WAGRRootSectionNative = 0,
    WAGRRootSectionFeatureSurfaces,
    WAGRRootSectionRuntime,
    WAGRRootSectionTools,
    WAGRRootSectionSystem,
};

typedef NS_ENUM(NSInteger, WAGRNativeRow) { WAGRNativeRowDeveloper = 0, WAGRNativeRowPrivateExperimentation };
typedef NS_ENUM(NSInteger, WAGRFeatureRow) { WAGRFeatureRowWAAB = 0, WAGRFeatureRowLiquidGlass, WAGRFeatureRowAura, WAGRFeatureRowDebugMenus };
typedef NS_ENUM(NSInteger, WAGRRuntimeRow) { WAGRRuntimeRowExec = 0, WAGRRuntimeRowSharedModules, WAGRRuntimeRowCurated };
typedef NS_ENUM(NSInteger, WAGRToolRow) { WAGRToolRowInstallPersisted = 0, WAGRToolRowDiagnostics, WAGRToolRowLogs };
typedef NS_ENUM(NSInteger, WAGRSystemRow) { WAGRSystemRowRestart = 0, WAGRSystemRowResetOverrides, WAGRSystemRowResetPrefs };

@implementation WAGRSurfaceListVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"WATweaks";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch ((WAGRRootSection)section) {
        case WAGRRootSectionNative: return 2;
        case WAGRRootSectionFeatureSurfaces: return 4;
        case WAGRRootSectionRuntime: return 3;
        case WAGRRootSectionTools: return 3;
        case WAGRRootSectionSystem: return 3;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch ((WAGRRootSection)section) {
        case WAGRRootSectionNative: return @"Menus nativos";
        case WAGRRootSectionFeatureSurfaces: return @"Features confirmadas no binário";
        case WAGRRootSectionRuntime: return @"Runtime por imagem Mach-O";
        case WAGRRootSectionTools: return @"Ferramentas";
        case WAGRRootSectionSystem: return @"Sistema";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WAGRRootSectionFeatureSurfaces) return @"Entradas baseadas em strings/classes confirmadas em WhatsApp(15) e SharedModules(19). Ajustes finos ficam dentro de cada superfície.";
    if (section == WAGRRootSectionRuntime) return @"Exec e SharedModules são separados por class_getImageName; sem ranking ou token semântico inventado.";
    return nil;
}

static NSDictionary *WAGRRow(NSString *title, NSString *sub, NSString *icon) {
    return @{ @"title": title ?: @"", @"sub": sub ?: @"", @"icon": icon ?: @"circle" };
}

- (NSDictionary *)rowForIndexPath:(NSIndexPath *)ip {
    if (ip.section == WAGRRootSectionNative) {
        return ip.row == WAGRNativeRowPrivateExperimentation
            ? WAGRRow(@"Private Experimentation", @"Controller nativo confirmado no executável", @"testtube.2")
            : WAGRRow(@"Developer Menu", @"WADebugViewController nativo", @"chevron.left.forwardslash.chevron.right");
    }
    if (ip.section == WAGRRootSectionFeatureSurfaces) {
        switch ((WAGRFeatureRow)ip.row) {
            case WAGRFeatureRowWAAB: return WAGRRow(@"WAAB / MobileConfig", @"FOAWAABPropertiesImpl + WAABProperties", @"switch.2");
            case WAGRFeatureRowLiquidGlass: return WAGRRow(@"Liquid Glass / WDS", @"WDSLiquidGlass, WDSExperiments, ios_liquid_glass_*", @"drop");
            case WAGRFeatureRowAura: return WAGRRow(@"Aura / Subscription", @"WAAuraGating + aura_subscription_simulation_enabled", @"star");
            case WAGRFeatureRowDebugMenus: return WAGRRow(@"Debug menu catalog", @"Menus e controllers encontrados no app", @"list.bullet.rectangle");
        }
    }
    if (ip.section == WAGRRootSectionRuntime) {
        switch ((WAGRRuntimeRow)ip.row) {
            case WAGRRuntimeRowExec: return WAGRRow(@"WhatsApp executable", @"Runtime browser separado do executável principal", @"app.dashed");
            case WAGRRuntimeRowSharedModules: return WAGRRow(@"SharedModules.framework", @"Runtime browser separado do framework", @"shippingbox");
            case WAGRRuntimeRowCurated: return WAGRRow(@"Runtime gates salvos", @"Overrides persistidos e categorias do hook router", @"rectangle.grid.2x2");
        }
    }
    if (ip.section == WAGRRootSectionTools) {
        switch ((WAGRToolRow)ip.row) {
            case WAGRToolRowInstallPersisted: return WAGRRow(@"Reinstalar hooks salvos", @"Reaplica overrides persistidos", @"arrow.triangle.2.circlepath");
            case WAGRToolRowDiagnostics: return WAGRRow(@"Diagnóstico", @"Router, LiquidGlass, runtime e keychain", @"doc.text.magnifyingglass");
            case WAGRToolRowLogs: return WAGRRow(@"Logs", @"Log interno do WATweaks", @"list.bullet.rectangle");
        }
    }
    switch ((WAGRSystemRow)ip.row) {
        case WAGRSystemRowRestart: return WAGRRow(@"Reiniciar WhatsApp", @"Fecha o app", @"power");
        case WAGRSystemRowResetOverrides: return WAGRRow(@"Reset overrides", @"Remove valores, índice de overrides e hooks runtime persistidos", @"arrow.counterclockwise");
        case WAGRSystemRowResetPrefs: return WAGRRow(@"Reset WATweaks prefs", @"Remove preferências watweak*/wagr*/wa*/WA*", @"trash");
    }
    return WAGRRow(@"", @"", @"circle");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = [self rowForIndexPath:ip];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(c, ip.row, row[@"title"]);
    c.textLabel.text = row[@"title"];
    c.detailTextLabel.text = row[@"sub"];
    c.detailTextLabel.numberOfLines = 0;
    c.imageView.image = WAGRMenuSymbol(row[@"icon"], nil);
    c.imageView.tintColor = WAGRMenuSecondaryTextColor();
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (ip.section == WAGRRootSectionSystem && ip.row == WAGRSystemRowRestart) c.textLabel.textColor = UIColor.systemRedColor;
    return c;
}

- (WAGRSurfaceSpec *)surfaceWithID:(NSString *)sid {
    for (WAGRSurfaceSpec *s in [WAGRSurfaceSpec allSurfaces]) if ([s.surfaceID isEqualToString:sid]) return s;
    return nil;
}

- (void)pushSurface:(NSString *)sid {
    WAGRSurfaceSpec *s = [self surfaceWithID:sid];
    if (!s) { WAGRAlert(@"Runtime", [NSString stringWithFormat:@"Surface %@ não encontrada.", sid]); return; }
    [self.navigationController pushViewController:[[WAGRSurfaceBrowserVC alloc] initWithSpec:s] animated:YES];
}

- (void)showDiagnostics {
    NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\nKeychain=%@",
                     WAGRGateStoreDiagnostic() ?: @"GateStore n/a",
                     WAGRHookRouterDiagnostic() ?: @"Router n/a",
                     WAGRLGDiagnosticText() ?: @"LiquidGlass n/a",
                     WAGRDogfoodDiagnosticText() ?: @"Runtime n/a",
                     WAKeychainAccessGroupDiagnostic() ?: @"n/a"];
    WAGRAlert(@"Diagnóstico", msg);
}


- (void)resetAllRuntimeOverrides {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset overrides"
                                                               message:@"Remove todos os valores watweak_gate_*, watweak_ui_*, o índice de overrides e o índice de hooks runtime persistidos. Reinicie o WhatsApp depois para descarregar hooks já instalados no processo atual."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUInteger n = WAGRGateClearAll();
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        WAGRAlert(@"Reset overrides", [NSString stringWithFormat:@"%lu entradas removidas. Reinicie o WhatsApp para descarregar hooks já instalados no processo atual.", (unsigned long)n]);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)resetKeysMatching:(BOOL (^)(NSString *key))match title:(NSString *)title restart:(BOOL)restart {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:@"Confirmar limpeza?" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSUInteger n = 0;
        for (NSString *k in ud.dictionaryRepresentation.allKeys) if (match(k)) { [ud removeObjectForKey:k]; n++; }
        [ud synchronize];
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        WAGRAlert(@"Reset", [NSString stringWithFormat:@"%lu chaves removidas.", (unsigned long)n]);
        if (restart) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == WAGRRootSectionNative) {
        UIViewController *presentedBy = self.presentingViewController;
        NSInteger row = ip.row;
        [self dismissViewControllerAnimated:YES completion:^{
            NSError *err = nil;
            BOOL ok = row == WAGRNativeRowPrivateExperimentation
                ? WAGRLaunchPrivateExperimentationDebug(presentedBy ?: WAGRTopController(), &err)
                : WAGRLaunchNativeDeveloperMenu(presentedBy ?: WAGRTopController(), &err);
            if (!ok) WAGRAlert(@"WATweaks", err.localizedDescription ?: @"Não foi possível abrir o menu nativo.");
        }];
        return;
    }

    if (ip.section == WAGRRootSectionFeatureSurfaces) {
        if (ip.row == WAGRFeatureRowWAAB) [self.navigationController pushViewController:[WAGRABPropsRootVC new] animated:YES];
        else if (ip.row == WAGRFeatureRowLiquidGlass) [self pushSurface:@"liquidglass"];
        else if (ip.row == WAGRFeatureRowAura) [self pushSurface:@"aura"];
        else [self.navigationController pushViewController:[WAGRSecretMenusVC new] animated:YES];
        return;
    }

    if (ip.section == WAGRRootSectionRuntime) {
        if (ip.row == WAGRRuntimeRowExec) [self pushSurface:@"exec"];
        else if (ip.row == WAGRRuntimeRowSharedModules) [self pushSurface:@"sharedmodules"];
        else [self.navigationController pushViewController:[WAGRRuntimeGatesVC new] animated:YES];
        return;
    }

    if (ip.section == WAGRRootSectionTools) {
        if (ip.row == WAGRToolRowInstallPersisted) {
            NSUInteger n = WAGRReinstallPersistedHooks();
            WAGRAlert(@"Hooks", [NSString stringWithFormat:@"%lu hooks reinstalados.", (unsigned long)n]);
        } else if (ip.row == WAGRToolRowDiagnostics) [self showDiagnostics];
        else [self.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
        return;
    }

    if (ip.section == WAGRRootSectionSystem) {
        if (ip.row == WAGRSystemRowRestart) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        else if (ip.row == WAGRSystemRowResetOverrides) [self resetAllRuntimeOverrides];
        else [self resetKeysMatching:^BOOL(NSString *key) { return [key hasPrefix:@"watweak"] || [key hasPrefix:@"wagr"] || [key hasPrefix:@"wa_"] || [key hasPrefix:@"WA"]; } title:@"Reset WATweaks prefs" restart:YES];
    }
}
@end
