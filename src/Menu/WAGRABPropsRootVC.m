#import "WAGRABPropsRootVC.h"
#import "WAGRGateCategoryVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRGateRegistry.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRLog.h"

extern BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);
extern NSString *WAGRCurrentUserContextDiagnostic(void);
extern NSString *WAGRDebugMenuLauncherDiagnosticText(void);
extern NSString *WAGRDebugMenuInstrumentationDiagnosticText(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern void WAGRGateHooksEnsureInstalled(void);

typedef NS_ENUM(NSInteger, WAGRABPropsSection) {
    WAGRABPropsSectionEntryPoints = 0,
    WAGRABPropsSectionFeatureBundles,
    WAGRABPropsSectionInfra,
    WAGRABPropsSectionCount
};

@interface WAGRABPropsRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *icon;
@property(nonatomic, copy) NSString *accentKey;
@property(nonatomic, copy, nullable) NSString *providerID;
@property(nonatomic, assign) NSInteger action;
+ (instancetype)rowWithTitle:(NSString *)title
                      detail:(NSString *)detail
                        icon:(NSString *)icon
                   accentKey:(NSString *)accentKey
                  providerID:(nullable NSString *)providerID
                      action:(NSInteger)action;
@end

@implementation WAGRABPropsRow
+ (instancetype)rowWithTitle:(NSString *)title
                      detail:(NSString *)detail
                        icon:(NSString *)icon
                   accentKey:(NSString *)accentKey
                  providerID:(NSString *)providerID
                      action:(NSInteger)action {
    WAGRABPropsRow *r = [self new];
    r.title = title ?: @"";
    r.detail = detail ?: @"";
    r.icon = icon ?: @"circle";
    r.accentKey = accentKey ?: title ?: @"";
    r.providerID = providerID;
    r.action = action;
    return r;
}
@end

typedef NS_ENUM(NSInteger, WAGRABPropsAction) {
    WAGRABPropsActionProvider = 0,
    WAGRABPropsActionPrivateExperimentation,
    WAGRABPropsActionRuntimeRoot,
    WAGRABPropsActionContextDiagnostic,
    WAGRABPropsActionLogs
};

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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Aplicar"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(applyVisibleOverrides)];
}

- (NSArray<NSArray<WAGRABPropsRow *> *> *)buildSections {
    NSArray<WAGRABPropsRow *> *entryPoints = @[
        [WAGRABPropsRow rowWithTitle:@"WAAB Feature Keys"
                              detail:@"Flags WAAB principais: LiquidGlass, Aura, Contacts, Payments, Companion e chaves AB gerais."
                                icon:@"switch.2"
                           accentKey:@"waab"
                          providerID:@"waab"
                              action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Fetch Experiments / Private Experimentation"
                              detail:@"Abre o fluxo Swift nativo com userContext real. Usa o mesmo caminho do Fetch Experiments."
                                icon:@"arrow.down.doc.fill"
                           accentKey:@"private_experimentation"
                          providerID:nil
                              action:WAGRABPropsActionPrivateExperimentation],
        [WAGRABPropsRow rowWithTitle:@"Todas as Categorias"
                              detail:@"Lista completa por provider, com Runtime Avançado dentro de cada categoria."
                                icon:@"square.grid.2x2.fill"
                           accentKey:@"runtime"
                          providerID:nil
                              action:WAGRABPropsActionRuntimeRoot]
    ];

    NSArray<WAGRABPropsRow *> *featureBundles = @[
        [WAGRABPropsRow rowWithTitle:@"LiquidGlass" detail:@"Milestones, chatbar, top bar, sidebar, media editor e workarounds." icon:@"sparkles" accentKey:@"liquidglass" providerID:@"liquidglass" action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Aura / WA Plus" detail:@"Aparência, temas, ícones, ringtones, stickers, subscriptions e benefícios." icon:@"wand.and.stars" accentKey:@"aura" providerID:@"aura" action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"About" detail:@"Evolve About M1, receiver, entrypoint e consumo da superfície About." icon:@"person.text.rectangle.fill" accentKey:@"about" providerID:@"about" action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Tab Me" detail:@"Me tab, status próprio, settings header/title, profile picture entrypoint e account switcher." icon:@"person.crop.circle.fill" accentKey:@"tab_me" providerID:@"tab_me" action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Evolution" detail:@"Parâmetros visuais modernos, botões de navegação e bridges do Evolve About." icon:@"arrow.triangle.2.circlepath.circle.fill" accentKey:@"evolution" providerID:@"evolution" action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Username" detail:@"Username privacy, global search, suggestions, migration, calling e companion." icon:@"at.circle.fill" accentKey:@"username" providerID:@"username" action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Online Contacts" detail:@"Contacts surface, ContactsHub, recently online, LID contacts e status audience." icon:@"person.2.wave.2.fill" accentKey:@"online_contacts" providerID:@"online_contacts" action:WAGRABPropsActionProvider]
    ];

    NSArray<WAGRABPropsRow *> *infra = @[
        [WAGRABPropsRow rowWithTitle:@"MobileConfig / Session Based"
                              detail:@"Session-based MC, stable ID cache, source of truth e rollback gates."
                                icon:@"slider.horizontal.3"
                           accentKey:@"mobileconfig"
                          providerID:@"mobileconfig"
                              action:WAGRABPropsActionProvider],
        [WAGRABPropsRow rowWithTitle:@"Context / PreFlight Inspector"
                              detail:@"Mostra userContext, launcher, DebugMenuSpy e GateHooks sem abrir o console."
                                icon:@"checklist.checked"
                           accentKey:@"context"
                          providerID:nil
                              action:WAGRABPropsActionContextDiagnostic],
        [WAGRABPropsRow rowWithTitle:@"WATweaks Log"
                              detail:@"Buffer desta sessão com botão de voltar, copiar, atualizar e limpar."
                                icon:@"doc.text.magnifyingglass"
                           accentKey:@"log"
                          providerID:nil
                              action:WAGRABPropsActionLogs]
    ];

    return @[ entryPoints, featureBundles, infra ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return WAGRABPropsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return 0;
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((WAGRABPropsSection)section) {
        case WAGRABPropsSectionEntryPoints:    return @"AB Props";
        case WAGRABPropsSectionFeatureBundles: return @"Categorias principais";
        case WAGRABPropsSectionInfra:          return @"Infra / Diagnóstico";
        case WAGRABPropsSectionCount:          return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == WAGRABPropsSectionEntryPoints) {
        return @"Esta tela substitui o yellow card da seção AB Props do Developer Menu sem mexer em WATableSection/WATableRow nativos.";
    }
    if (section == WAGRABPropsSectionFeatureBundles) {
        return @"Cada categoria abre toggles principais e Runtime Avançado. O botão Aplicar instala hooks para overrides já definidos, ignorando negative/kill/disable por segurança.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WAGRABPropsRow *row = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRABPropsRootCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRABPropsRootCell"];

    WAGRMenuApplyCellStyle(cell, indexPath.row, row.accentKey);
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = [self detailForRow:row];
    cell.detailTextLabel.numberOfLines = 0;
    UIColor *accent = WAGRMenuAccentForKey(row.accentKey, indexPath.row);
    cell.imageView.image = WAGRMenuSymbol(row.icon, nil);
    cell.imageView.tintColor = accent;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"WAGRABProps.%@", row.providerID ?: row.title];
    return cell;
}

- (NSString *)detailForRow:(WAGRABPropsRow *)row {
    if (!row.providerID.length) return row.detail;
    WAGRGateProvider *provider = [WAGRGateRegistry providerWithID:row.providerID];
    NSUInteger overrides = [self overrideCountForProvider:provider];
    if (!overrides) return row.detail;
    return [NSString stringWithFormat:@"%@ · %lu overrides", row.detail, (unsigned long)overrides];
}

- (NSUInteger)overrideCountForProvider:(WAGRGateProvider *)provider {
    if (!provider) return 0;
    NSArray<NSString *> *all = WAGRGateAllOverrides();
    if (!all.count || !provider.featured.count) return 0;
    NSMutableSet<NSString *> *keys = [NSMutableSet setWithCapacity:provider.featured.count];
    for (WAGRGateFeaturedFlag *f in provider.featured) {
        if (f.selectorName.length) [keys addObject:WAGRGateCanonicalKey(f.selectorName)];
    }
    NSUInteger count = 0;
    for (NSString *key in all) if ([keys containsObject:WAGRGateCanonicalKey(key)]) count++;
    return count;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGRABPropsRow *row = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    [self openRow:row];
}

#pragma mark - Actions

- (void)openRow:(WAGRABPropsRow *)row {
    switch ((WAGRABPropsAction)row.action) {
        case WAGRABPropsActionProvider: {
            WAGRGateProvider *provider = [WAGRGateRegistry providerWithID:row.providerID];
            if (!provider) {
                [self showAlert:@"Provider ausente" message:[NSString stringWithFormat:@"Não encontrei providerID=%@.", row.providerID ?: @"nil"]];
                return;
            }
            [self.navigationController pushViewController:[[WAGRGateCategoryVC alloc] initWithProvider:provider] animated:YES];
            return;
        }
        case WAGRABPropsActionPrivateExperimentation: {
            NSError *err = nil;
            BOOL ok = WAGRLaunchPrivateExperimentationDebug(self, &err);
            if (!ok) [self showAlert:@"Private Experimentation" message:err.localizedDescription ?: @"Não foi possível abrir."];
            return;
        }
        case WAGRABPropsActionRuntimeRoot:
            [self.navigationController pushViewController:[WAGRRuntimeGatesVC new] animated:YES];
            return;
        case WAGRABPropsActionContextDiagnostic:
            [self showContextDiagnostic];
            return;
        case WAGRABPropsActionLogs:
            [self.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
            return;
    }
}

- (void)showContextDiagnostic {
    NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@",
                     WAGRCurrentUserContextDiagnostic() ?: @"UserContext: n/a",
                     WAGRDebugMenuLauncherDiagnosticText() ?: @"Launcher: n/a",
                     WAGRDebugMenuInstrumentationDiagnosticText() ?: @"DebugMenuSpy: n/a",
                     WAGRGateHooksDiagnostic() ?: @"GateHooks: n/a"];
    [self showAlert:@"Context / PreFlight" message:msg];
}

- (void)applyVisibleOverrides {
    WAGRGateHooksEnsureInstalled();
    NSArray<NSString *> *overrideKeys = WAGRGateAllOverrides();
    NSUInteger total = 0;
    NSUInteger skipped = 0;
    for (NSString *key in overrideKeys) {
        total++;
        if (WAGRMenuIsNegativeGateName(key)) skipped++;
    }
    NSString *msg = [NSString stringWithFormat:@"Overrides ativos: %lu\nIgnorados por segurança: %lu\nHooks centrais foram solicitados. Para hooks diretos, abra a categoria específica e use Aplicar.",
                     (unsigned long)total, (unsigned long)skipped];
    [self showAlert:@"Aplicar AB Props" message:msg];
    [self.tableView reloadData];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"WATweaks"
                                                                   message:message ?: @""
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        UIPasteboard.generalPasteboard.string = message ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
