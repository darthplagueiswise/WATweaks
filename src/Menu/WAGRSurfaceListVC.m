// WAGRSurfaceListVC.m — RyukGram-style WAGram root menu.
// Long-press activation is kept in Tweak.x. This file only changes the UI hierarchy:
// feature bundles first, raw runtime browser only under Avançado.

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import "WAGRSurfaceListVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRSecretMenusVC.h"
#import "WAGRLogViewController.h"
#import "WAGRRuntimeGatesVC.h"
#import "../WAGramPrefix.h"
#import "../WAUtils.h"
#import "../Runtime/WAGRSurface.h"

extern void WAGRWAABEnsureHooksInstalled(void);
// The native dev-menu launcher lives in src/Hooks/WAGRDebugMenuLauncher.xm.
// It does the heavy lifting of locating a WAContextMain and instantiating
// WADebugViewController via initWithUserContext:.
extern BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);
extern BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);
extern NSString *WAGRDebugMenuLauncherDiagnosticText(void);
static UIColor *WAGRBG(void)     { return UIColor.systemGroupedBackgroundColor; }
static UIColor *WAGRCell(void)   { return UIColor.secondarySystemGroupedBackgroundColor; }
static UIColor *WAGRText(void)   { return UIColor.labelColor; }
static UIColor *WAGRSub(void)    { return UIColor.secondaryLabelColor; }
static UIColor *WAGRBlue(void)   { return UIColor.systemBlueColor; }
static UIColor *WAGRRed(void)    { return UIColor.systemRedColor; }

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

@interface WAGRRawSurfaceListVC : UITableViewController
@property(nonatomic, strong) NSArray<WAGRSurfaceSpec *> *surfaces;
@end

@implementation WAGRRawSurfaceListVC
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Runtime Avançado";
    _surfaces = [WAGRSurfaceSpec allSurfaces];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)_surfaces.count; }
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.font = [UIFont boldSystemFontOfSize:11];
        h.textLabel.textColor = [UIColor colorWithWhite:.5 alpha:1];
    }
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return @"Surfaces técnicas"; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    return @"Browser bruto para debug. A UI principal usa bundles compactos.";
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    WAGRSurfaceSpec *s = _surfaces[(NSUInteger)ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = s.title;
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = s.subtitle ?: @"";
    c.detailTextLabel.textColor = WAGRSub();
    c.imageView.image = [[UIImage systemImageNamed:s.icon ?: @"circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRText();
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    WAGRSurfaceBrowserVC *vc = [[WAGRSurfaceBrowserVC alloc] initWithSpec:_surfaces[(NSUInteger)ip.row]];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

typedef NS_ENUM(NSInteger, WAGRRootSection) {
    // The native dev-menu launcher sits at the top so it is the very first
    // thing the user sees when the WATweaks sheet opens. It is the headline
    // action — most users only want this one button.
    WAGRRootSectionDevMenu = 0,
    // Curated list of ~25 hidden WhatsApp debug VCs that ship in the
    // binary but are not exposed in normal UI. One tap = try every known
    // init signature and present the controller modally.
    WAGRRootSectionSecret,
    WAGRRootSectionAbout,
    // "Avançado" owns both curated runtime gate categories and the raw
    // technical browser. The curated row is intentionally first because it is
    // the readable UI; the raw browser remains available for low-level debug.
    WAGRRootSectionAdvanced,
    WAGRRootSectionSystem,
};

// One row inside the new top section.
typedef NS_ENUM(NSInteger, WAGRDevMenuRow) {
    WAGRDevMenuRowOpen = 0,
    WAGRDevMenuRowPrivateExperimentation,
};

typedef NS_ENUM(NSInteger, WAGRAdvancedRow) {
    WAGRAdvancedRowRuntimeGates = 0,
    WAGRAdvancedRowRawRuntime,
    WAGRAdvancedRowInstallPersisted,
    WAGRAdvancedRowDiagnostics,
    WAGRAdvancedRowLogs,
};

typedef NS_ENUM(NSInteger, WAGRSystemRow) {
    WAGRSystemRowRestart = 0,
    WAGRSystemRowResetOverrides,
    WAGRSystemRowResetWAGramPrefs,
};

@interface WAGRSurfaceListVC ()
@end

@implementation WAGRSurfaceListVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"WATweaks";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(done)];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch ((WAGRRootSection)section) {
        case WAGRRootSectionDevMenu: return 2;
        case WAGRRootSectionSecret: return 1;
        case WAGRRootSectionAbout: return 1;
        case WAGRRootSectionAdvanced: return 5;
        case WAGRRootSectionSystem: return 3;
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
    switch ((WAGRRootSection)section) {
        case WAGRRootSectionDevMenu: return @"Menu Developer Nativo";
        case WAGRRootSectionSecret: return @"Menus Secretos do App";
        case WAGRRootSectionAbout: return nil;
        case WAGRRootSectionAdvanced: return @"Avançado";
        case WAGRRootSectionSystem: return @"Sistema";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WAGRRootSectionAdvanced)
        return @"Use \"Runtime Gates por Categoria\" para a UI legível com categorias. "
               @"Use \"Runtime Browser Bruto\" só para debug técnico de classes/surfaces.";
    return nil;
}

// The headline action: a single, prominent cell that directly invokes the
// native WADebugViewController bypassing all gating. The blue tint and the
// `</>` SF Symbol match the visual contract of WhatsApp's own Developer row.
- (UITableViewCell *)devMenuCellForRow:(NSInteger)row {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.textColor = WAGRSub();

    if (row == WAGRDevMenuRowPrivateExperimentation) {
        c.textLabel.text = @"Abrir Private Experimentation";
        c.detailTextLabel.text = @"Usa o userContext real capturado do WADebugViewController";
        UIImage *icon = [UIImage systemImageNamed:@"testtube.2"];
        if (!icon) icon = [UIImage systemImageNamed:@"flask"];
        c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        c.imageView.tintColor = UIColor.systemPurpleColor;
    } else {
        c.textLabel.text = @"Abrir Menu Developer Nativo";
        c.detailTextLabel.text = @"Apresenta WADebugViewController pelo provider nativo";
        UIImage *icon = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
        if (!icon) icon = [UIImage systemImageNamed:@"curlybraces"];
        c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        c.imageView.tintColor = UIColor.systemBlueColor;
    }

    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (UITableViewCell *)aboutCell {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = @"WATweaks";
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = @"Runtime router · MSHookMessageEx · UI compacta";
    c.detailTextLabel.textColor = WAGRSub();
    c.imageView.image = [[UIImage systemImageNamed:@"bolt.horizontal.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRText();
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (UITableViewCell *)advancedCellForRow:(NSInteger)row {
    NSString *titles[] = {
        @"Runtime Gates por Categoria",
        @"Runtime Browser Bruto",
        @"Instalar hooks salvos",
        @"Diagnóstico",
        @"Logs WATweaks"
    };
    NSString *subs[] = {
        @"Categorias legíveis: WAAB, Aura, MobileConfig, Internal, Settings",
        @"Surfaces técnicas: WAABProperties, WAContextMain, WAAuraGating etc.",
        @"Reinstala overrides persistidos",
        @"Router, LiquidGlass, Dogfood, Keychain",
        @"UserContext, PrivateExperimentation e hooks nativos"
    };
    NSString *icons[] = {
        @"rectangle.grid.2x2",
        @"terminal",
        @"arrow.triangle.2.circlepath",
        @"doc.text.magnifyingglass",
        @"list.bullet.rectangle"
    };

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = titles[row];
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = subs[row];
    c.detailTextLabel.textColor = WAGRSub();
    c.detailTextLabel.numberOfLines = 0;
    c.imageView.image = [[UIImage systemImageNamed:icons[row]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRText();
    c.accessoryType = (row == WAGRAdvancedRowRuntimeGates ||
                       row == WAGRAdvancedRowRawRuntime ||
                       row == WAGRAdvancedRowLogs)
        ? UITableViewCellAccessoryDisclosureIndicator
        : UITableViewCellAccessoryNone;
    return c;
}

- (UITableViewCell *)systemCellForRow:(NSInteger)row {
    NSString *titles[] = { @"Reiniciar WhatsApp", @"Reset overrides", @"Reset WATweaks prefs" };
    NSString *subs[] = { @"Fecha o app", @"Remove wagr.override.* e wagr.observed.*", @"Remove preferências wagr*/wa* do tweak" };
    NSString *icons[] = { @"power", @"arrow.counterclockwise", @"trash" };

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = titles[row];
    c.textLabel.textColor = row == WAGRSystemRowRestart ? WAGRRed() : WAGRText();
    c.detailTextLabel.text = subs[row];
    c.detailTextLabel.textColor = WAGRSub();
    c.imageView.image = [[UIImage systemImageNamed:icons[row]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRText();
    return c;
}

// Single cell for the Secret menus entry. The "key" icon and the
// orange tint signal that this is an "unlocks something usually hidden"
// action — different visual contract from the blue dev-menu launcher
// and the per-area cells so the user can tell them apart at a glance.
- (UITableViewCell *)secretMenusCell {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = @"Painel Internal / Aura";
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = @"Masters de internal/employee + Aura, diagnóstico ao vivo, lista de Debug VCs";
    c.detailTextLabel.textColor = WAGRSub();
    UIImage *icon = [UIImage systemImageNamed:@"key.fill"];
    if (!icon) icon = [UIImage systemImageNamed:@"lock.open.fill"];
    c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = UIColor.systemOrangeColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch ((WAGRRootSection)ip.section) {
        case WAGRRootSectionDevMenu: return [self devMenuCellForRow:ip.row];
        case WAGRRootSectionSecret:  return [self secretMenusCell];
        case WAGRRootSectionAbout:   return [self aboutCell];
        case WAGRRootSectionAdvanced:return [self advancedCellForRow:ip.row];
        case WAGRRootSectionSystem:  return [self systemCellForRow:ip.row];
    }
    return [UITableViewCell new];
}

- (void)showDiagnostics {
    NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\nKeychain=%@",
                     WAGRHookRouterDiagnostic() ?: @"Router n/a",
                     WAGRLGDiagnosticText() ?: @"LiquidGlass n/a",
                     WAGRDogfoodDiagnosticText() ?: @"Dogfood n/a",
                     WAKeychainAccessGroupDiagnostic() ?: @"n/a"];
    WAGRAlert(@"Diagnóstico", msg);
}

- (void)resetKeysMatching:(BOOL (^)(NSString *key))match title:(NSString *)title restart:(BOOL)restart {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:@"Confirmar limpeza?"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSUInteger n = 0;
        for (NSString *k in ud.dictionaryRepresentation.allKeys) {
            if (match(k)) { [ud removeObjectForKey:k]; n++; }
        }
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

    if (ip.section == WAGRRootSectionDevMenu) {
        UIViewController *presentedBy = self.presentingViewController;
        NSInteger row = ip.row;
        [self dismissViewControllerAnimated:YES completion:^{
            NSError *err = nil;
            BOOL ok = NO;
            if (row == WAGRDevMenuRowPrivateExperimentation) {
                ok = WAGRLaunchPrivateExperimentationDebug(presentedBy ?: WAGRTopController(), &err);
                if (!ok) WAGRAlert(@"Não foi possível abrir Private Experimentation", err.localizedDescription ?: @"Erro desconhecido.");
            } else {
                ok = WAGRLaunchNativeDeveloperMenu(presentedBy ?: WAGRTopController(), &err);
                if (!ok) WAGRAlert(@"Não foi possível abrir o menu nativo", err.localizedDescription ?: @"Erro desconhecido.");
            }
        }];
        return;
    }

    if (ip.section == WAGRRootSectionSecret) {
        // Push the dedicated VC. Stays inside the WATweaks navigation stack
        // — the user can back out and pick a different one without leaving
        // the WATweaks menu.
        WAGRSecretMenusVC *vc = [[WAGRSecretMenusVC alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    if (ip.section == WAGRRootSectionAbout) {
        WAGRAlert(@"WATweaks", @"Acesse este menu de duas formas: (1) long-press no item Ajuda, Developer ou WATweaks da tela de Configurações do WhatsApp, ou (2) toque na linha WATweaks que aparece abaixo do Developer em Configurações.");
        return;
    }

    if (ip.section == WAGRRootSectionAdvanced) {
        if (ip.row == WAGRAdvancedRowRuntimeGates) {
            [self.navigationController pushViewController:[WAGRRuntimeGatesVC new] animated:YES];
        } else if (ip.row == WAGRAdvancedRowRawRuntime) {
            [self.navigationController pushViewController:[WAGRRawSurfaceListVC new] animated:YES];
        } else if (ip.row == WAGRAdvancedRowInstallPersisted) {
            NSUInteger n = WAGRReinstallPersistedHooks();
            WAGRAlert(@"Hooks", [NSString stringWithFormat:@"%lu hooks reinstalados.", (unsigned long)n]);
        } else if (ip.row == WAGRAdvancedRowDiagnostics) {
            [self showDiagnostics];
        } else if (ip.row == WAGRAdvancedRowLogs) {
            [self.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
        }
        return;
    }

    if (ip.section == WAGRRootSectionSystem) {
        if (ip.row == WAGRSystemRowRestart) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        } else if (ip.row == WAGRSystemRowResetOverrides) {
            [self resetKeysMatching:^BOOL(NSString *key) {
                return [key hasPrefix:@"wagr.override"] || [key hasPrefix:@"wagr.observed"];
            } title:@"Reset overrides" restart:NO];
        } else {
            [self resetKeysMatching:^BOOL(NSString *key) {
                return [key hasPrefix:@"wagr"] || [key hasPrefix:@"wa_"] || [key hasPrefix:@"WA"];
            } title:@"Reset WAGram prefs" restart:YES];
        }
    }
}

@end
