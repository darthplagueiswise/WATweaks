#import "WAGRMobileConfigExportVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRLog.h"

@interface WAGRMobileConfigExportVC ()
@property(nonatomic, strong) id userContext;
@property(nonatomic, copy) NSArray<WAGRMobileConfigMapping *> *allMappings;
@property(nonatomic, copy) NSArray<WAGRMobileConfigMapping *> *visibleMappings;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIBarButtonItem *scanButton;
@property(nonatomic, strong) UIBarButtonItem *exportButton;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) NSUInteger translatedCount;
@property(nonatomic, assign) NSUInteger resolvedCount;
@end

@implementation WAGRMobileConfigExportVC

- (instancetype)initWithUserContext:(id)userContext {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _userContext = userContext;
    _allMappings = @[];
    _visibleMappings = @[];
    self.title = @"AB → MobileConfig";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 86.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"WA ID, config ID, nome, param ou specifier";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.searchController = search;

    self.scanButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(scanNow)];
    if (@available(iOS 13.0, *)) {
        self.exportButton = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
            style:UIBarButtonItemStylePlain target:self action:@selector(showExportMenu:)];
    } else {
        self.exportButton = [[UIBarButtonItem alloc]
            initWithTitle:@"Exportar" style:UIBarButtonItemStylePlain
            target:self action:@selector(showExportMenu:)];
    }
    self.exportButton.enabled = NO;
    self.navigationItem.rightBarButtonItems = @[self.exportButton, self.scanButton];
    [self installHeader];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.allMappings.count && !self.scanning) [self scanNow];
}

- (void)installHeader {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 98)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = WAGRMenuSecondaryTextColor();
    label.numberOfLines = 3;
    label.text = @"Pronto para resolver o schema MobileConfig vivo.";
    [container addSubview:label];
    self.statusLabel = label;

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:progress];
    self.progressView = progress;

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:14],
        [progress.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [progress.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
        [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:12],
    ]];
    self.tableView.tableHeaderView = container;
}

- (void)setStatus:(NSString *)status progress:(float)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status ?: @"";
        self.progressView.progress = MIN(1.0f, MAX(0.0f, progress));
    });
}

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.scanButton.enabled = NO;
    self.exportButton.enabled = NO;
    self.title = @"Resolvendo MobileConfig…";
    [self setStatus:@"Capturando FBMobileConfigContextManager…" progress:0.0f];

    id context = self.userContext;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<WAGRMobileConfigMapping *> *mappings = WAGRMobileConfigResolveAll(
            context,
            ^(NSUInteger current, NSUInteger total, NSUInteger translated, NSUInteger resolved) {
                float fraction = total ? ((float)current / (float)total) : 0.0f;
                NSString *message = [NSString stringWithFormat:
                    @"%lu / %lu IDs · %lu traduzidos · %lu config IDs resolvidos",
                    (unsigned long)current, (unsigned long)total,
                    (unsigned long)translated, (unsigned long)resolved];
                [self setStatus:message progress:fraction];
            }, &error);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.scanButton.enabled = YES;
            if (!mappings) {
                self.title = @"AB → MobileConfig";
                [self setStatus:error.localizedDescription ?: @"Falha ao resolver MobileConfig." progress:0.0f];
                [self showAlert:@"MobileConfig" message:error.localizedDescription ?: @"Falha ao resolver o schema vivo."];
                return;
            }
            self.allMappings = mappings;
            NSUInteger resolved = 0;
            for (WAGRMobileConfigMapping *mapping in mappings) if (mapping.externalConfigStableId) resolved++;
            self.translatedCount = mappings.count;
            self.resolvedCount = resolved;
            self.exportButton.enabled = mappings.count > 0;
            [self applyFilter];

            NSString *namesPath = WAGRMobileConfigNamesPath(context);
            BOOL namesLoaded = namesPath.length && [[NSFileManager defaultManager] fileExistsAtPath:namesPath];
            [self setStatus:[NSString stringWithFormat:
                @"%lu traduzidos · %lu externos resolvidos · nomes %@",
                (unsigned long)mappings.count, (unsigned long)resolved,
                namesLoaded ? @"carregados" : @"ainda não materializados"] progress:1.0f];
        });
    });
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController {
    [self applyFilter];
}

- (void)applyFilter {
    NSString *query = [self.searchController.searchBar.text.lowercaseString
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!query.length) {
        self.visibleMappings = self.allMappings;
    } else {
        NSArray<NSString *> *tokens = [query componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray *filtered = [NSMutableArray array];
        for (WAGRMobileConfigMapping *mapping in self.allMappings) {
            NSString *haystack = [NSString stringWithFormat:
                @"%lu %llu %u %u %u %@ %@ 0x%016llx",
                (unsigned long)mapping.waStableId,
                mapping.externalConfigStableId,
                mapping.localConfigIndex,
                mapping.parameterIndex,
                mapping.parameterStableId,
                mapping.configName ?: @"",
                mapping.parameterName ?: @"",
                mapping.paramSpecifier].lowercaseString;
            BOOL matches = YES;
            for (NSString *token in tokens) {
                if (token.length && ![haystack containsString:token]) { matches = NO; break; }
            }
            if (matches) [filtered addObject:mapping];
        }
        self.visibleMappings = filtered;
    }
    self.title = [NSString stringWithFormat:@"AB → MC (%lu)",
                  (unsigned long)self.visibleMappings.count];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.visibleMappings.count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return @"Mapeamento vivo";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    NSString *overrides = WAGRMobileConfigOverridesPath(self.userContext) ?: @"não capturado";
    NSString *names = WAGRMobileConfigNamesPath(self.userContext) ?: @"não capturado";
    return [NSString stringWithFormat:
        @"mc_overrides: %@\n\nid_name_mapping: %@\n\n"
         "O scan não usa os 51 IDs antigos: percorre o domínio WA stable-ID validado do build e resolve cada entrada pelo WAMCEvaluation + FBMobileConfigContextManager.",
        overrides, names];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRMobileConfigMapCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMobileConfigMapping *mapping = self.visibleMappings[(NSUInteger)indexPath.row];
    WAGRMenuApplyCellStyle(cell, indexPath.row, mapping.parameterName ?: @"mobileconfig");
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 4;

    NSString *external = mapping.externalConfigStableId
        ? [NSString stringWithFormat:@"%llu", mapping.externalConfigStableId] : @"unresolved";
    NSString *name = mapping.parameterName.length ? mapping.parameterName
        : (mapping.configName.length ? mapping.configName : @"sem nomes materializados");
    cell.textLabel.text = [NSString stringWithFormat:@"WA %lu → MC %@ / p%u",
        (unsigned long)mapping.waStableId, external, mapping.parameterIndex];
    cell.detailTextLabel.text = [NSString stringWithFormat:
        @"%@\nconfig=%@ · local=%u · paramStable=%u · type=%u\nspec=0x%016llx",
        name, mapping.configName ?: @"—", mapping.localConfigIndex,
        mapping.parameterStableId, mapping.nativeType, mapping.paramSpecifier];
    cell.detailTextLabel.textColor = mapping.externalConfigStableId
        ? WAGRMenuSecondaryTextColor() : UIColor.systemOrangeColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.visibleMappings.count) return;
    WAGRMobileConfigMapping *mapping = self.visibleMappings[(NSUInteger)indexPath.row];
    id current = WAGRMobileConfigCurrentValue(mapping, self.userContext);
    NSString *message = [NSString stringWithFormat:
        @"WA stable ID: %lu\nparamSpecifier: 0x%016llx\nlocalConfigIndex: %u\nparameterIndex: %u\nparameterStableId: %u\ntype: %u\nexternal config ID: %@\nconfig: %@\nparameter: %@\ncurrent MC value: %@",
        (unsigned long)mapping.waStableId, mapping.paramSpecifier,
        mapping.localConfigIndex, mapping.parameterIndex, mapping.parameterStableId,
        mapping.nativeType,
        mapping.externalConfigStableId ? [NSString stringWithFormat:@"%llu", mapping.externalConfigStableId] : @"unresolved",
        mapping.configName ?: @"—", mapping.parameterName ?: @"—", current ?: @"unreadable"];
    [self showAlert:@"Mapping" message:message];
}

- (void)showExportMenu:(UIBarButtonItem *)sender {
    if (!self.allMappings.count) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Exportar MobileConfig"
        message:@"Escolha o artefato. As opções geram arquivos para compartilhar; não gravam overrides no container."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Crosswalk completo" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf exportCrosswalk]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · snapshot atual" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf exportOverridesMode:WAGRMobileConfigOverrideExportModeCurrentSnapshot];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · todas BOOL = true" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf confirmAllBooleansExport]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnóstico / paths" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf showAlert:@"MobileConfig runtime" message:WAGRMobileConfigDiagnosticText()];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) popover.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmAllBooleansExport {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Todas BOOL = true"
        message:@"O arquivo inclui todas as entradas booleanas com config ID externo resolvido. Importar tudo simultaneamente pode combinar features incompatíveis."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Exportar" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf exportOverridesMode:WAGRMobileConfigOverrideExportModeAllBooleansTrue];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportCrosswalk {
    [self exportJSONObject:WAGRMobileConfigCrosswalkDocument(self.allMappings, self.userContext)
                   filename:@"whatsapp_abprop_mobileconfig_crosswalk.json" completion:nil];
}

- (void)exportOverridesMode:(WAGRMobileConfigOverrideExportMode)mode {
    self.exportButton.enabled = NO;
    self.scanButton.enabled = NO;
    [self setStatus:@"Lendo valores MobileConfig para export…" progress:1.0f];
    id context = self.userContext;
    NSArray *mappings = self.allMappings;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *stats = nil;
        NSDictionary *document = WAGRMobileConfigOverrideDocument(mappings, context, mode, &stats);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exportButton.enabled = YES;
            self.scanButton.enabled = YES;
            NSString *filename = mode == WAGRMobileConfigOverrideExportModeAllBooleansTrue
                ? @"mc_overrides_all_bool_true.json" : @"mc_overrides_snapshot.json";
            [self exportJSONObject:document filename:filename completion:^{
                [self setStatus:[NSString stringWithFormat:
                    @"configs=%@ · params=%@ · unresolved=%@ · dedupe=%@",
                    stats[@"configs"] ?: @0, stats[@"emitted"] ?: @0,
                    stats[@"skipped_unresolved_external_id"] ?: @0,
                    stats[@"deduplicated"] ?: @0] progress:1.0f];
            }];
        });
    });
}

- (void)exportJSONObject:(id)object filename:(NSString *)filename completion:(void (^ _Nullable)(void))completion {
    NSError *error = nil;
    NSData *data = WAGRMobileConfigJSONData(object, &error);
    if (!data.length) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Não foi possível serializar JSON."];
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:filename ?: @"mobileconfig.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Não foi possível gravar o arquivo temporário."];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) popover.barButtonItem = self.exportButton;
    if (completion) completion();
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"MobileConfig"
        message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { UIPasteboard.generalPasteboard.string = message ?: @""; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
