#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "WAGRSurfaceListVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRABPropsRootVC.h"
#import "WAGRLogViewController.h"
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
        for (UIWindow *w in ((UIWindowScene *)sc).windows) { if (w.isKeyWindow) { c = w.rootViewController; break; } }
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

typedef NS_ENUM(NSInteger, WAGRRootSection) { WAGRRootSectionMain = 0, WAGRRootSectionTools, WAGRRootSectionSystem };
typedef NS_ENUM(NSInteger, WAGRMainRow) { WAGRMainRowAB = 0, WAGRMainRowExec, WAGRMainRowShared, WAGRMainRowInternal };
typedef NS_ENUM(NSInteger, WAGRToolRow) { WAGRToolRowApply = 0, WAGRToolRowDiagnostics, WAGRToolRowLogs };
typedef NS_ENUM(NSInteger, WAGRSystemRow) { WAGRSystemRowReset = 0, WAGRSystemRowRestart };

@implementation WAGRSurfaceListVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"WATweaks";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 76.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(done)];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; WAGRMenuApplyTableStyle(self.tableView, self); [self.tableView reloadData]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; WAGRApplyLiquidGlassToViewTree(self.view); }
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == WAGRRootSectionMain) return 4;
    if (section == WAGRRootSectionTools) return 3;
    return 2;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == WAGRRootSectionMain) return @"Runtime";
    if (section == WAGRRootSectionTools) return @"Ferramentas";
    return @"Sistema";
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WAGRRootSectionMain) return @"Uma raiz única: ABProperties live em ordem alfabética e dois browsers runtime por imagem Mach-O. Sem subcategorias inventadas.";
    if (section == WAGRRootSectionSystem) return @"Reset limpa somente o prefixo único watweak_* e o índice de hooks persistidos.";
    return nil;
}

static NSDictionary *WAGRRow(NSString *title, NSString *sub, NSString *icon) {
    return @{ @"title": title ?: @"", @"sub": sub ?: @"", @"icon": icon ?: @"circle" };
}

- (NSDictionary *)rowForIndexPath:(NSIndexPath *)ip {
    if (ip.section == WAGRRootSectionMain) {
        switch ((WAGRMainRow)ip.row) {
            case WAGRMainRowAB: return WAGRRow(@"ABProperties live", @"Lido em runtime pelo hook central WAAB; nomes resolvidos por mapeamento do próprio app quando disponível.", @"switch.2");
            case WAGRMainRowExec: return WAGRRow(@"Runtime — WhatsApp", @"Classes do executável principal, agrupadas só por prefixo de classe.", @"app.dashed");
            case WAGRMainRowShared: return WAGRRow(@"Runtime — SharedModules", @"Classes do framework, agrupadas só por prefixo de classe.", @"shippingbox");
            case WAGRMainRowInternal: return WAGRRow(@"Developer / Dogfood / Internal", @"Abre o caminho nativo sem inserir row da tweak dentro do WhatsApp.", @"ladybug");
        }
    }
    if (ip.section == WAGRRootSectionTools) {
        switch ((WAGRToolRow)ip.row) {
            case WAGRToolRowApply: return WAGRRow(@"Aplicar hooks persistidos", @"Reinstala os hooks salvos no índice runtime.", @"arrow.triangle.2.circlepath");
            case WAGRToolRowDiagnostics: return WAGRRow(@"Diagnóstico", @"GateStore, router, LiquidGlass, Dogfood e keychain.", @"doc.text.magnifyingglass");
            case WAGRToolRowLogs: return WAGRRow(@"Logs", @"Log interno da sessão.", @"list.bullet.rectangle");
        }
    }
    switch ((WAGRSystemRow)ip.row) {
        case WAGRSystemRowReset: return WAGRRow(@"Reset WATweaks", @"Remove watweak_* e índices runtime. Reinicia para descarregar hooks já instalados.", @"trash");
        case WAGRSystemRowRestart: return WAGRRow(@"Reiniciar WhatsApp", @"Fecha o app para aplicar estado limpo.", @"power");
    }
    return WAGRRow(@"", @"", @"circle");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = [self rowForIndexPath:ip];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(cell, ip.row, row[@"title"]);
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"sub"];
    cell.imageView.image = WAGRMenuSymbol(row[@"icon"], nil);
    cell.imageView.tintColor = WAGRMenuSecondaryTextColor();
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (ip.section == WAGRRootSectionSystem && ip.row == WAGRSystemRowRestart) cell.textLabel.textColor = UIColor.systemRedColor;
    return cell;
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
- (void)resetAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset WATweaks" message:@"Remove todos os overrides com prefixo watweak_* e os índices runtime. Reinicia o WhatsApp depois." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUInteger n = WAGRGateClearAll();
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        for (NSString *key in ud.dictionaryRepresentation.allKeys) {
            if ([key hasPrefix:@"watweak_"] || [key hasPrefix:@"watweak."]) { [ud removeObjectForKey:key]; n++; }
        }
        [ud synchronize];
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        WAGRAlert(@"Reset", [NSString stringWithFormat:@"%lu entradas removidas. Reiniciando...", (unsigned long)n]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == WAGRRootSectionMain) {
        if (ip.row == WAGRMainRowAB) [self.navigationController pushViewController:[WAGRABPropsRootVC new] animated:YES];
        else if (ip.row == WAGRMainRowExec) [self pushSurface:@"exec"];
        else if (ip.row == WAGRMainRowShared) [self pushSurface:@"sharedmodules"];
        else {
            UIViewController *presentedBy = self.presentingViewController ?: self;
            [self dismissViewControllerAnimated:YES completion:^{
                NSError *err = nil;
                BOOL ok = WAGRLaunchNativeDeveloperMenu(presentedBy ?: WAGRTopController(), &err);
                if (!ok) WAGRAlert(@"Developer / Dogfood / Internal", err.localizedDescription ?: @"Não foi possível abrir o menu nativo.");
            }];
        }
        return;
    }
    if (ip.section == WAGRRootSectionTools) {
        if (ip.row == WAGRToolRowApply) {
            NSUInteger n = WAGRReinstallPersistedHooks();
            WAGRAlert(@"Hooks", [NSString stringWithFormat:@"%lu hooks/overrides considerados.", (unsigned long)n]);
        } else if (ip.row == WAGRToolRowDiagnostics) [self showDiagnostics];
        else [self.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
        return;
    }
    if (ip.row == WAGRSystemRowReset) [self resetAll];
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}

@end
