// WAGRSurfaceListVC.m — RyukGram-style WAGram root menu.
// Long-press activation is kept in Tweak.x. This file only changes the UI hierarchy:
// feature bundles first, raw runtime browser only under Avançado.

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import "WAGRSurfaceListVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRGatingCatalog.h"
#import "WAGRGatingAreaMenuVC.h"
#import "WAGRSecretMenusVC.h"
#import "WAGRDebugVCInstantiatorVC.h"
#import "WAGRSettingsBackup.h"
#import "../Runtime/WAGRRuntimeInventory.h"
#import "../WAGramPrefix.h"
#import "../WAUtils.h"
#import "../Runtime/WAGRSurface.h"

extern void WAGRWAABEnsureHooksInstalled(void);
// The native dev-menu launcher lives in src/Hooks/WAGRDebugMenuLauncher.xm.
// It does the heavy lifting of locating a WAContextMain and instantiating
// WADebugViewController via initWithUserContext:.
extern BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);
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

static NSUInteger WAGROverrideCountForSurfaceID(NSString *sid) {
    if (!sid.length) return 0;
    NSString *prefix = [NSString stringWithFormat:@"wagr.override|%@|", sid];
    NSString *legacy = [NSString stringWithFormat:@"wagr.override.%@.", sid];
    NSUInteger n = 0;
    for (NSString *k in NSUserDefaults.standardUserDefaults.dictionaryRepresentation.allKeys)
        if ([k hasPrefix:prefix] || [k hasPrefix:legacy]) n++;
    return n;
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
    return @"Browser bruto para debug: WAABProperties, WAContext, WAContextMain, WAAuraGating e demais surfaces técnicas.";
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
    // Secret tools section: Internal/Aura control panel + safe Debug VC Lab.
    // The lab lists hidden Debug VCs but does not raw-instantiate them.
    WAGRRootSectionSecret,
    // The new curated, data-driven gating-area menus. Each row pushes a
    // WAGRGatingAreaMenuVC seeded with that area's catalog entries. This
    // is the primary path going forward — the older "Categorias" section
    // (bundle scans) is kept below for backward compatibility.
    WAGRRootSectionAreas,
    WAGRRootSectionAbout,
    WAGRRootSectionBundles,
    WAGRRootSectionAdvanced,
    WAGRRootSectionSystem,
};

// One row inside the new top section.

typedef NS_ENUM(NSInteger, WAGRSecretRow) {
    WAGRSecretRowInternalAura = 0,
    WAGRSecretRowDebugVCLab,
    WAGRSecretRowCount,
};

typedef NS_ENUM(NSInteger, WAGRDevMenuRow) {
    WAGRDevMenuRowOpen = 0,
};

typedef NS_ENUM(NSInteger, WAGRAdvancedRow) {
    WAGRAdvancedRowWAAB = 0,
    WAGRAdvancedRowWAContext,
    WAGRAdvancedRowWAContextMain,
    WAGRAdvancedRowWAAuraGating,
    WAGRAdvancedRowWAServerProperties,
    WAGRAdvancedRowWAMobileConfig,
    WAGRAdvancedRowFOA,
    WAGRAdvancedRowBiz,
    WAGRAdvancedRowRawRuntime,
    WAGRAdvancedRowInstallPersisted,
    WAGRAdvancedRowDiagnostics,
    WAGRAdvancedRowCount,
};

typedef NS_ENUM(NSInteger, WAGRSystemRow) {
    WAGRSystemRowExportBackup = 0,
    WAGRSystemRowImportBackup,
    WAGRSystemRowRestart,
    WAGRSystemRowResetOverrides,
    WAGRSystemRowResetWATweaksPrefs,
};

@interface WAGRSurfaceListVC () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<WAGRSurfaceSpec *> *bundles;
@property(nonatomic, strong) NSArray<WAGRSurfaceSpec *> *filteredBundles;
@property(nonatomic, strong) UISearchController *search;
@end

@implementation WAGRSurfaceListVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"WATweaks";
    _bundles = [WAGRSurfaceSpec featureBundles];
    _filteredBundles = _bundles;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(done)];

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"Buscar configurações";
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text.lowercaseString ?: @"";
    if (!q.length) {
        _filteredBundles = _bundles;
    } else {
        _filteredBundles = [_bundles filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WAGRSurfaceSpec *s, NSDictionary *_) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@", s.title ?: @"", s.subtitle ?: @""].lowercaseString;
            return [hay containsString:q];
        }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 7; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch ((WAGRRootSection)section) {
        case WAGRRootSectionDevMenu: return 1;
        case WAGRRootSectionSecret: return WAGRSecretRowCount;
        case WAGRRootSectionAreas: return (NSInteger)WAGRGatingAreaCount;
        case WAGRRootSectionAbout: return 1;
        case WAGRRootSectionBundles: return (NSInteger)_filteredBundles.count;
        case WAGRRootSectionAdvanced: return WAGRAdvancedRowCount;
        case WAGRRootSectionSystem: return 5;
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
        case WAGRRootSectionAreas: return @"Áreas de Gating (Curadas)";
        case WAGRRootSectionAbout: return nil;
        case WAGRRootSectionBundles: return @"Categorias";
        case WAGRRootSectionAdvanced: return @"Avançado";
        case WAGRRootSectionSystem: return @"Sistema";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WAGRRootSectionBundles)
        return @"Os bundles usam scan direcionado por tokens/classes e exibem apenas features compactas.";
    if (section == WAGRRootSectionAdvanced)
        return @"Runtime bruto fica aqui, separado do menu normal.";
    return nil;
}

// The headline action: a single, prominent cell that directly invokes the
// native WADebugViewController bypassing all gating. The blue tint and the
// `</>` SF Symbol match the visual contract of WhatsApp's own Developer row.
- (UITableViewCell *)devMenuCell {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = @"Abrir Menu Developer Nativo";
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = @"Apresenta WADebugViewController diretamente";
    c.detailTextLabel.textColor = WAGRSub();
    UIImage *icon = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
    if (!icon) icon = [UIImage systemImageNamed:@"curlybraces"];
    c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = UIColor.systemBlueColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

// Cell for a single gating area. The icon and tint reflect the area's
// semantic (drop for LiquidGlass, star for Aura, eye-slash for hidden rows,
// etc.). The detail line shows the curated-entry count so the user knows
// at a glance whether the area is populated yet.
- (UITableViewCell *)areaCellForRow:(NSInteger)row {
    WAGRGatingArea area = (WAGRGatingArea)row;
    NSUInteger count = [WAGRGatingCatalog countForArea:area];

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = WAGRGatingAreaTitle(area);
    c.textLabel.textColor = WAGRText();

    NSString *baseSub = WAGRGatingAreaSubtitle(area) ?: @"";
    NSString *suffix = count == 0 ? @"  ·  vazio (catálogo pendente)"
                                  : [NSString stringWithFormat:@"  ·  %lu gates", (unsigned long)count];
    c.detailTextLabel.text = [baseSub stringByAppendingString:suffix];
    c.detailTextLabel.textColor = count == 0 ? UIColor.tertiaryLabelColor : WAGRSub();

    UIImage *icon = [UIImage systemImageNamed:WAGRGatingAreaIconName(area)];
    if (!icon) icon = [UIImage systemImageNamed:@"circle.grid.2x2.fill"];
    c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRTintForBundleTitle(WAGRGatingAreaTitle(area));
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

// Maps a bundle's title fragment to a category-specific tint. The intent is
// to make the menu scannable at a glance: blue for general-platform items
// like LiquidGlass, purple for premium/business gates, green for status and
// calls, orange for AI, red for privacy. Falls back to system gray for any
// title the map does not recognize.
static UIColor *WAGRTintForBundleTitle(NSString *title) {
    NSString *t = title.lowercaseString ?: @"";
    if ([t containsString:@"contact"])      return UIColor.systemCyanColor;
    if ([t containsString:@"evolve"] || [t containsString:@"about"])
                                            return UIColor.systemPinkColor;
    if ([t containsString:@"linked"] || [t containsString:@"primary"] || [t containsString:@"companion"])
                                            return UIColor.systemTealColor;
    if ([t containsString:@"group"])        return UIColor.systemIndigoColor;
    if ([t containsString:@"payment"] || [t containsString:@"pix"] || [t containsString:@"upi"])
                                            return UIColor.systemGrayColor;
    if ([t containsString:@"foa"] || [t containsString:@"facebook"] || [t containsString:@"instagram"] || [t containsString:@"threads"])
                                            return UIColor.systemTealColor;
    if ([t containsString:@"biz"] || [t containsString:@"business"] || [t containsString:@"smb"] || [t containsString:@"catalog"])
                                            return UIColor.systemYellowColor;
    if ([t containsString:@"liquid"])       return UIColor.systemBlueColor;
    if ([t containsString:@"aura"] || [t containsString:@"plus"])
                                            return UIColor.systemPurpleColor;
    if ([t containsString:@"status"])       return UIColor.systemGreenColor;
    if ([t containsString:@"channel"])      return UIColor.systemTealColor;
    if ([t containsString:@"call"])         return UIColor.systemGreenColor;
    if ([t containsString:@"mensag"] || [t containsString:@"messag"])
                                            return UIColor.systemBlueColor;
    if ([t containsString:@"ai"] || [t containsString:@"meta"])
                                            return UIColor.systemOrangeColor;
    if ([t containsString:@"privacy"] || [t containsString:@"username"])
                                            return UIColor.systemRedColor;
    if ([t containsString:@"premium"] || [t containsString:@"business"])
                                            return UIColor.systemYellowColor;
    if ([t containsString:@"setting"] || [t containsString:@"row"])
                                            return UIColor.systemIndigoColor;
    if ([t containsString:@"geral"] || [t containsString:@"general"])
                                            return UIColor.systemGrayColor;
    return [UIColor colorWithRed:0.6 green:0.65 blue:0.75 alpha:1.0];
}

- (UITableViewCell *)bundleCellForRow:(NSInteger)row {
    WAGRSurfaceSpec *s = _filteredBundles[(NSUInteger)row];
    NSUInteger count = WAGROverrideCountForSurfaceID(s.surfaceID);
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = s.title;
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = count ? [NSString stringWithFormat:@"%lu overrides", (unsigned long)count] : (s.subtitle ?: @"");
    c.detailTextLabel.textColor = WAGRSub();
    c.imageView.image = [[UIImage systemImageNamed:s.icon ?: @"circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRTintForBundleTitle(s.title);
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

static WAGRSurfaceSpec *WAGRRawSurfaceSpecForAdvancedRow(NSInteger row) {
    NSString *wanted = nil;
    switch ((WAGRAdvancedRow)row) {
        case WAGRAdvancedRowWAAB: wanted = kWAGRSurfaceWAAB; break;
        case WAGRAdvancedRowWAContext: wanted = kWAGRSurfaceContext; break;
        case WAGRAdvancedRowWAContextMain: wanted = @"contextmain_graph"; break;
        case WAGRAdvancedRowWAAuraGating: wanted = kWAGRSurfaceAura; break;
        case WAGRAdvancedRowWAServerProperties: wanted = kWAGRSurfaceServer; break;
        case WAGRAdvancedRowWAMobileConfig: wanted = kWAGRSurfaceMobileConfig; break;
        case WAGRAdvancedRowFOA: wanted = kWAGRSurfaceFOA; break;
        case WAGRAdvancedRowBiz: wanted = kWAGRSurfaceBiz; break;
        default: return nil;
    }
    for (WAGRSurfaceSpec *spec in [WAGRSurfaceSpec allSurfaces]) {
        if ([spec.surfaceID isEqualToString:wanted]) return spec;
    }
    return nil;
}

- (UITableViewCell *)advancedCellForRow:(NSInteger)row {
    NSString *titles[] = {
        @"Runtime WAABProperties",
        @"Runtime WAContext",
        @"Runtime WAContextMain",
        @"Runtime WAAuraGating",
        @"Runtime WAServerProperties",
        @"Runtime WAMobileConfig",
        @"Runtime FOA / Meta Apps",
        @"Runtime WABiz / Business",
        @"Runtime Browser Avançado",
        @"Instalar hooks salvos",
        @"Diagnóstico"
    };
    NSString *subs[] = {
        @"AB props/feature flags reais; aplica stubs com o router runtime.",
        @"Gates do WAContext antes da expansão para WAContextMain.",
        @"Object graph/gates grandes do WAContextMain.",
        @"Providers Swift Aura/GatedBenefit/GatedSubscription.",
        @"Gate central de internal/server/userContext.",
        @"Fetch/cache/GraphQL/gating bridge por trás do WAAB.",
        @"Facebook, Instagram, Threads, Meta AI e FOA bridges.",
        @"BizManager, BizProfile, SMB, merchant e catalog.",
        @"Lista todas as surfaces técnicas disponíveis.",
        @"Reinstala overrides persistidos via MSHookMessageEx.",
        @"Router, inventory, backup, LiquidGlass, Dogfood, SettingsRows, Keychain."
    };
    NSString *icons[] = {
        @"switch.2", @"point.3.connected.trianglepath.dotted", @"cube.transparent", @"star", @"server.rack", @"network", @"apps.iphone", @"briefcase", @"terminal", @"arrow.triangle.2.circlepath", @"doc.text.magnifyingglass"
    };

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = titles[row];
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.text = subs[row];
    c.detailTextLabel.textColor = WAGRSub();
    c.detailTextLabel.numberOfLines = 2;
    c.imageView.image = [[UIImage systemImageNamed:icons[row]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = WAGRText();
    c.accessoryType = (row <= WAGRAdvancedRowRawRuntime) ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}

- (UITableViewCell *)systemCellForRow:(NSInteger)row {
    NSString *titles[] = { @"Exportar backup JSON", @"Importar backup JSON", @"Reiniciar WhatsApp", @"Reset overrides", @"Reset WATweaks prefs" };
    NSString *subs[] = { @"Exporta preferências e overrides do WATweaks", @"Importa como espelho: ausentes no JSON são removidos", @"Fecha o app", @"Remove todos os runtime overrides, WAAB overrides e observed", @"Remove todas as preferências gerenciadas pelo WATweaks" };
    NSString *icons[] = { @"square.and.arrow.up", @"square.and.arrow.down", @"power", @"arrow.counterclockwise", @"trash" };

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
- (UITableViewCell *)secretMenusCellForRow:(NSInteger)row {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    if (row == WAGRSecretRowDebugVCLab) {
        c.textLabel.text = @"Debug VC Lab";
        c.detailTextLabel.text = @"Lista/probe dos Debug VCs; bloqueia alloc/init cru que causa Swift trap";
        UIImage *icon = [UIImage systemImageNamed:@"stethoscope"];
        if (!icon) icon = [UIImage systemImageNamed:@"ladybug.fill"];
        c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        c.imageView.tintColor = UIColor.systemRedColor;
    } else {
        c.textLabel.text = @"Painel Internal / Aura";
        c.detailTextLabel.text = @"Masters de internal/employee + Aura, diagnóstico ao vivo, lista de Debug VCs";
        UIImage *icon = [UIImage systemImageNamed:@"key.fill"];
        if (!icon) icon = [UIImage systemImageNamed:@"lock.open.fill"];
        c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        c.imageView.tintColor = UIColor.systemOrangeColor;
    }
    c.textLabel.textColor = WAGRText();
    c.detailTextLabel.textColor = WAGRSub();
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch ((WAGRRootSection)ip.section) {
        case WAGRRootSectionDevMenu: return [self devMenuCell];
        case WAGRRootSectionSecret:  return [self secretMenusCellForRow:ip.row];
        case WAGRRootSectionAreas:   return [self areaCellForRow:ip.row];
        case WAGRRootSectionAbout:   return [self aboutCell];
        case WAGRRootSectionBundles: return [self bundleCellForRow:ip.row];
        case WAGRRootSectionAdvanced:return [self advancedCellForRow:ip.row];
        case WAGRRootSectionSystem:  return [self systemCellForRow:ip.row];
    }
    return [UITableViewCell new];
}

- (void)showDiagnostics {
    NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n%@\n\nKeychain=%@",
                     WAGRHookRouterDiagnostic() ?: @"Router n/a",
                     WAGRLGDiagnosticText() ?: @"LiquidGlass n/a",
                     WAGRDogfoodDiagnosticText() ?: @"Dogfood n/a",
                     WAGRRuntimeInventoryDiagnosticText() ?: @"Inventory n/a",
                     WAGRSettingsBackupDiagnosticText() ?: @"Backup n/a",
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
        // Dismiss the WATweaks sheet first, then launch the native menu from
        // the underlying VC. We do this in sequence (dismiss → launch in the
        // completion block) because UIKit only allows one modal at a time
        // from a given presenter, and the native dev menu is itself going to
        // be presented modally on top of WhatsApp's settings hierarchy.
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

    if (ip.section == WAGRRootSectionSecret) {
        if (ip.row == WAGRSecretRowDebugVCLab) {
            WAGRDebugVCInstantiatorVC *vc = [[WAGRDebugVCInstantiatorVC alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            WAGRSecretMenusVC *vc = [[WAGRSecretMenusVC alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }

    if (ip.section == WAGRRootSectionAreas) {
        WAGRGatingArea area = (WAGRGatingArea)ip.row;
        WAGRGatingAreaMenuVC *vc = [[WAGRGatingAreaMenuVC alloc] initWithArea:area];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    if (ip.section == WAGRRootSectionAbout) {
        WAGRAlert(@"WATweaks", @"Acesse este menu por long-press no item Ajuda/Developer da tela de Configurações ou pelo gesto global de abertura do WATweaks. A tweak não injeta mais linha/botão dentro dos menus nativos do WhatsApp.");
        return;
    }

    if (ip.section == WAGRRootSectionBundles) {
        WAGRSurfaceSpec *spec = _filteredBundles[(NSUInteger)ip.row];
        WAGRSurfaceBrowserVC *vc = [[WAGRSurfaceBrowserVC alloc] initWithSpec:spec];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    if (ip.section == WAGRRootSectionAdvanced) {
        WAGRSurfaceSpec *direct = WAGRRawSurfaceSpecForAdvancedRow(ip.row);
        if (direct) {
            WAGRSurfaceBrowserVC *vc = [[WAGRSurfaceBrowserVC alloc] initWithSpec:direct];
            [self.navigationController pushViewController:vc animated:YES];
        } else if (ip.row == WAGRAdvancedRowRawRuntime) {
            [self.navigationController pushViewController:[WAGRRawSurfaceListVC new] animated:YES];
        } else if (ip.row == WAGRAdvancedRowInstallPersisted) {
            NSUInteger n = WAGRReinstallPersistedHooks();
            WAGRAlert(@"Hooks", [NSString stringWithFormat:@"%lu hooks reinstalados.", (unsigned long)n]);
        } else {
            [self showDiagnostics];
        }
        return;
    }

    if (ip.section == WAGRRootSectionSystem) {
        if (ip.row == WAGRSystemRowExportBackup) {
            [WAGRSettingsBackup presentExport];
        } else if (ip.row == WAGRSystemRowImportBackup) {
            [WAGRSettingsBackup presentImport];
        } else if (ip.row == WAGRSystemRowRestart) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        } else if (ip.row == WAGRSystemRowResetOverrides) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset overrides"
                                                                       message:@"Remove todos os runtime overrides, WAAB overrides, observed values e hooks persistidos. Reinicie para descarregar hooks já instalados no processo atual."
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
                NSUInteger n = WAGRClearRuntimeOverridePreferences();
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
                WAGRAlert(@"Reset overrides", [NSString stringWithFormat:@"%lu chaves removidas. Reinicie o WhatsApp para descarregar hooks já instalados.", (unsigned long)n]);
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        } else {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset WATweaks prefs"
                                                                       message:@"Remove todas as preferências gerenciadas pelo WATweaks e reinicia o app."
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
                NSUInteger n = WAGRClearAllManagedPreferences();
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
                WAGRAlert(@"Reset WATweaks prefs", [NSString stringWithFormat:@"%lu chaves removidas. Reiniciando...", (unsigned long)n]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
    }
}

@end
