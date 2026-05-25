// WAGRSurfaceListVC.m — root WATweaks menu, post-unification.
// ─────────────────────────────────────────────────────────────────────────────
// Sections (top to bottom)
//   1. Menu Developer Nativo — opens WhatsApp's hidden WADebugViewController
//   2. Menus Secretos        — Internal/Aura simulation + Debug VC Lab
//   3. Runtime Gates         — the new unified, category-driven gate browser
//   4. Sobre                 — short usage note
//   5. Sistema               — backup / restart / reset
//
// Everything that used to live under "Categorias", "Avançado" and the
// duplicate raw-surface list has been folded into Runtime Gates. There is
// now exactly one runtime browser; categories surface their featured flags
// at the top and a "Runtime Avançado" button drills into the full live
// selector list for that category.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRSurfaceListVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRSecretMenusVC.h"
#import "WAGRDebugVCInstantiatorVC.h"
#import "WAGRSettingsBackup.h"
#import "../Runtime/WAGRRuntimeInventory.h"
#import "../Runtime/WAGRGateStore.h"
#import "../WAGramPrefix.h"
#import "../WAUtils.h"

extern BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);

static UIColor *WAGRBG(void)   { return UIColor.systemGroupedBackgroundColor; }
static UIColor *WAGRText(void) { return UIColor.labelColor; }
static UIColor *WAGRSub(void)  { return UIColor.secondaryLabelColor; }
static UIColor *WAGRRed(void)  { return UIColor.systemRedColor; }

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
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"WATweaks"
                                                                   message:message ?: @""
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused id _) {
            UIPasteboard.generalPasteboard.string = message ?: @"";
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [WAGRTopController() presentViewController:a animated:YES completion:nil];
    });
}

typedef NS_ENUM(NSInteger, WAGRRoot) {
    WAGRRootDevMenu = 0,
    WAGRRootSecret,
    WAGRRootGates,
    WAGRRootAbout,
    WAGRRootSystem,
    WAGRRootCount
};

typedef NS_ENUM(NSInteger, WAGRGatesRow) {
    WAGRGatesRowOpen = 0,
    WAGRGatesRowDiagnostics,
    WAGRGatesRowResetOverrides,
    WAGRGatesRowCount
};

typedef NS_ENUM(NSInteger, WAGRSecretRow) {
    WAGRSecretRowInternalAura = 0,
    WAGRSecretRowDebugVCLab,
    WAGRSecretRowCount
};

typedef NS_ENUM(NSInteger, WAGRSystemRow) {
    WAGRSystemRowExportBackup = 0,
    WAGRSystemRowImportBackup,
    WAGRSystemRowRestart,
    WAGRSystemRowResetAll,
    WAGRSystemRowCount
};

@implementation WAGRSurfaceListVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"WATweaks";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(done)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return WAGRRootCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch ((WAGRRoot)section) {
        case WAGRRootDevMenu: return 1;
        case WAGRRootSecret:  return WAGRSecretRowCount;
        case WAGRRootGates:   return WAGRGatesRowCount;
        case WAGRRootAbout:   return 1;
        case WAGRRootSystem:  return WAGRSystemRowCount;
        case WAGRRootCount:   return 0;
    }
    return 0;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.font = [UIFont boldSystemFontOfSize:11];
        h.textLabel.textColor = [UIColor colorWithWhite:.5 alpha:1];
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch ((WAGRRoot)section) {
        case WAGRRootDevMenu: return @"Menu Developer Nativo";
        case WAGRRootSecret:  return @"Menus Secretos do App";
        case WAGRRootGates:   return @"Runtime Gates";
        case WAGRRootAbout:   return nil;
        case WAGRRootSystem:  return @"Sistema";
        case WAGRRootCount:   return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WAGRRootGates) {
        return @"Cada categoria mostra os flags principais e dá acesso ao runtime avançado para edição fina.";
    }
    if (section == WAGRRootSystem) {
        return @"Backup exporta apenas chaves wagr*/wa*. Reset apaga todos os overrides salvos.";
    }
    return nil;
}

- (UITableViewCell *)cellWithTitle:(NSString *)title
                          subtitle:(NSString *)subtitle
                              icon:(NSString *)icon
                              tint:(UIColor *)tint
                         accessory:(UITableViewCellAccessoryType)acc {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = title;
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = subtitle ?: @"";
    c.detailTextLabel.textColor = WAGRSub();
    c.detailTextLabel.numberOfLines = 0;
    UIImage *img = [UIImage systemImageNamed:icon ?: @"circle"];
    c.imageView.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = tint ?: WAGRText();
    c.accessoryType = acc;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch ((WAGRRoot)ip.section) {
        case WAGRRootDevMenu:
            return [self cellWithTitle:@"Abrir Menu Developer Nativo"
                              subtitle:@"Apresenta WADebugViewController diretamente"
                                  icon:@"chevron.left.forwardslash.chevron.right"
                                  tint:UIColor.systemBlueColor
                             accessory:UITableViewCellAccessoryDisclosureIndicator];
        case WAGRRootSecret:
            if (ip.row == WAGRSecretRowDebugVCLab) {
                return [self cellWithTitle:@"Debug VC Lab"
                                  subtitle:@"Lista/probe de Debug VCs; bloqueia alloc/init cru que traps em Swift."
                                      icon:@"stethoscope"
                                      tint:UIColor.systemRedColor
                                 accessory:UITableViewCellAccessoryDisclosureIndicator];
            }
            return [self cellWithTitle:@"Painel Internal / Aura"
                              subtitle:@"Masters Internal/Employee + Aura, diagnóstico ao vivo, lista de Debug VCs."
                                  icon:@"key.fill"
                                  tint:UIColor.systemOrangeColor
                             accessory:UITableViewCellAccessoryDisclosureIndicator];
        case WAGRRootGates: {
            switch ((WAGRGatesRow)ip.row) {
                case WAGRGatesRowOpen: {
                    NSUInteger overrides = WAGRGateAllOverrides().count;
                    NSString *sub = overrides
                        ? [NSString stringWithFormat:@"%lu overrides ativos · categorias + runtime avançado",
                           (unsigned long)overrides]
                        : @"Categorias curadas (LiquidGlass, Aura, MobileConfig, ...) + runtime avançado.";
                    return [self cellWithTitle:@"Abrir Runtime Gates"
                                      subtitle:sub
                                          icon:@"switch.2"
                                          tint:UIColor.systemGreenColor
                                     accessory:UITableViewCellAccessoryDisclosureIndicator];
                }
                case WAGRGatesRowDiagnostics:
                    return [self cellWithTitle:@"Diagnóstico"
                                      subtitle:@"Storage, hooks, router, LiquidGlass, Aura, Dogfood, Settings Rows, Keychain."
                                          icon:@"doc.text.magnifyingglass"
                                          tint:WAGRText()
                                     accessory:UITableViewCellAccessoryNone];
                case WAGRGatesRowResetOverrides:
                    return [self cellWithTitle:@"Reset overrides"
                                      subtitle:@"Remove todos os overrides salvos (mantém prefs masters)."
                                          icon:@"arrow.counterclockwise"
                                          tint:WAGRRed()
                                     accessory:UITableViewCellAccessoryNone];
                case WAGRGatesRowCount: break;
            }
            break;
        }
        case WAGRRootAbout:
            return [self cellWithTitle:@"WATweaks"
                              subtitle:@"Long-press em Ajuda/Developer no Settings, ou toque na linha WATweaks abaixo de Developer."
                                  icon:@"info.circle"
                                  tint:WAGRText()
                             accessory:UITableViewCellAccessoryNone];
        case WAGRRootSystem: {
            switch ((WAGRSystemRow)ip.row) {
                case WAGRSystemRowExportBackup:
                    return [self cellWithTitle:@"Exportar backup JSON"
                                      subtitle:@"Exporta preferências e overrides do WATweaks."
                                          icon:@"square.and.arrow.up"
                                          tint:WAGRText()
                                     accessory:UITableViewCellAccessoryNone];
                case WAGRSystemRowImportBackup:
                    return [self cellWithTitle:@"Importar backup JSON"
                                      subtitle:@"Modo espelho: chaves ausentes no JSON são removidas."
                                          icon:@"square.and.arrow.down"
                                          tint:WAGRText()
                                     accessory:UITableViewCellAccessoryNone];
                case WAGRSystemRowRestart:
                    return [self cellWithTitle:@"Reiniciar WhatsApp"
                                      subtitle:@"Fecha o app para aplicar mudanças."
                                          icon:@"power"
                                          tint:WAGRRed()
                                     accessory:UITableViewCellAccessoryNone];
                case WAGRSystemRowResetAll:
                    return [self cellWithTitle:@"Reset WATweaks prefs"
                                      subtitle:@"Remove TODAS as preferências do WATweaks (wagr*, wa_*)."
                                          icon:@"trash"
                                          tint:WAGRRed()
                                     accessory:UITableViewCellAccessoryNone];
                case WAGRSystemRowCount: break;
            }
            break;
        }
        case WAGRRootCount: break;
    }
    return [[UITableViewCell alloc] init];
}

#pragma mark - Selection

- (void)showDiagnostics {
    NSString *msg = [NSString stringWithFormat:
        @"[Store]\n%@\n\n[GateHooks]\n%@\n\n[AuraNav]\n%@\n\n[LiquidGlass]\n%@\n\n[Dogfood]\n%@\n\n[Inventory]\n%@\n\n[Backup]\n%@\n\nKeychain=%@",
        WAGRGateStoreDiagnostic() ?: @"n/a",
        WAGRGateHooksDiagnostic() ?: @"n/a",
        WAGRAuraNavigationDiagnostic() ?: @"n/a",
        WAGRLGDiagnosticText() ?: @"n/a",
        WAGRDogfoodDiagnosticText() ?: @"n/a",
        WAGRRuntimeInventoryDiagnosticText() ?: @"n/a",
        WAGRSettingsBackupDiagnosticText() ?: @"n/a",
        WAKeychainAccessGroupDiagnostic() ?: @"n/a"];
    WAGRAlert(@"Diagnóstico", msg);
}

- (void)confirmResetOverrides {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset overrides"
                                                               message:@"Remover todos os overrides salvos?"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUInteger n = WAGRGateClearAll();
        WAGRAlert(@"Reset", [NSString stringWithFormat:@"%lu overrides removidos.", (unsigned long)n]);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmResetAllPrefs {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset WATweaks prefs"
                                                               message:@"Remover TODAS as preferências do WATweaks? Esta ação reinicia o app."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSUInteger n = 0;
        for (NSString *k in ud.dictionaryRepresentation.allKeys) {
            if ([k hasPrefix:@"wagr"] || [k hasPrefix:@"wa_"] || [k hasPrefix:@"WA"]) {
                [ud removeObjectForKey:k];
                n++;
            }
        }
        [ud synchronize];
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        WAGRAlert(@"Reset", [NSString stringWithFormat:@"%lu chaves removidas. Reiniciando…", (unsigned long)n]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    switch ((WAGRRoot)ip.section) {
        case WAGRRootDevMenu: {
            UIViewController *presentedBy = self.presentingViewController;
            [self dismissViewControllerAnimated:YES completion:^{
                NSError *err = nil;
                BOOL ok = WAGRLaunchNativeDeveloperMenu(presentedBy ?: WAGRTopController(), &err);
                if (!ok) {
                    WAGRAlert(@"Não foi possível abrir o menu nativo",
                              err.localizedDescription ?: @"Erro desconhecido.");
                }
            }];
            return;
        }
        case WAGRRootSecret: {
            if (ip.row == WAGRSecretRowDebugVCLab) {
                WAGRDebugVCInstantiatorVC *vc = [[WAGRDebugVCInstantiatorVC alloc] init];
                [self.navigationController pushViewController:vc animated:YES];
            } else {
                WAGRSecretMenusVC *vc = [[WAGRSecretMenusVC alloc] init];
                [self.navigationController pushViewController:vc animated:YES];
            }
            return;
        }
        case WAGRRootGates: {
            switch ((WAGRGatesRow)ip.row) {
                case WAGRGatesRowOpen: {
                    WAGRRuntimeGatesVC *vc = [[WAGRRuntimeGatesVC alloc] init];
                    [self.navigationController pushViewController:vc animated:YES];
                    return;
                }
                case WAGRGatesRowDiagnostics:
                    [self showDiagnostics];
                    return;
                case WAGRGatesRowResetOverrides:
                    [self confirmResetOverrides];
                    return;
                case WAGRGatesRowCount: return;
            }
            return;
        }
        case WAGRRootAbout:
            WAGRAlert(@"WATweaks",
                @"Long-press no item Ajuda, Developer ou WATweaks da tela de Configurações do WhatsApp, "
                @"ou toque na linha WATweaks que aparece abaixo do Developer em Configurações.");
            return;
        case WAGRRootSystem: {
            switch ((WAGRSystemRow)ip.row) {
                case WAGRSystemRowExportBackup: [WAGRSettingsBackup presentExport]; return;
                case WAGRSystemRowImportBackup: [WAGRSettingsBackup presentImport]; return;
                case WAGRSystemRowRestart:
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ exit(0); });
                    return;
                case WAGRSystemRowResetAll: [self confirmResetAllPrefs]; return;
                case WAGRSystemRowCount: return;
            }
            return;
        }
        case WAGRRootCount: return;
    }
}

@end
