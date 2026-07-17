#import "WAGRABPropsRootVC.h"
#import "WAGRABPropsBrowserVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRLog.h"

extern BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);
extern NSString *WAGRCurrentUserContextDiagnostic(void);
extern NSString *WAGRDebugMenuLauncherDiagnosticText(void);
extern NSString *WAGRDebugMenuInstrumentationDiagnosticText(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern id WAGRCurrentUserContext(void);
extern void WAGRGateHooksEnsureInstalled(void);

typedef NS_ENUM(NSInteger, WAGRABPropsAction) {
    WAGRABPropsActionLiveBrowser = 0,
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
}

- (NSArray<NSArray<WAGRABPropsRow *> *> *)buildSections {
    NSArray<WAGRABPropsRow *> *runtime = @[
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
                              detail:@"UserContext, launcher, DebugMenu instrumentation, GateHooks e estatísticas do último scan vivo."
                                icon:@"checklist.checked"
                           accentKey:@"context"
                              action:WAGRABPropsActionContextDiagnostic],
        [WAGRABPropsRow rowWithTitle:@"WATweaks Log"
                              detail:@"Logs desta sessão, incluindo resolução de objetos WAAB e scans do runtime."
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
    return section == 0 ? @"Runtime ao vivo" : @"Diagnóstico";
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return @"WAABProperties existe no Objective-C runtime. As linhas são reconstruídas ao abrir/atualizar o browser; JSON não participa da descoberta nem da categorização.";
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
        case WAGRABPropsActionLiveBrowser: {
            id context = WAGRCurrentUserContext();
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
    NSDictionary *stats = WAGRABPropsCatalogStats();
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n[WAAB live stats]\n%@",
                         WAGRCurrentUserContextDiagnostic() ?: @"UserContext: n/a",
                         WAGRDebugMenuLauncherDiagnosticText() ?: @"Launcher: n/a",
                         WAGRDebugMenuInstrumentationDiagnosticText() ?: @"DebugMenuSpy: n/a",
                         WAGRGateHooksDiagnostic() ?: @"GateHooks: n/a",
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
