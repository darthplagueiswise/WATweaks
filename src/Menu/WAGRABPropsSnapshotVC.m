#import "WAGRABPropsSnapshotVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRLog.h"

@interface WAGRABPropsSnapshotVC ()
@property(nonatomic, strong) id userContext;
@property(nonatomic, strong) WAGRABPropsNativeSnapshot *snapshot;
@property(nonatomic, copy) NSDictionary *exportDocument;
@property(nonatomic, copy) NSArray<NSDictionary *> *allEntries;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleEntries;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UIBarButtonItem *fetchButton;
@property(nonatomic, strong) UIBarButtonItem *exportButton;
@property(nonatomic, assign) BOOL fetching;
@end

@implementation WAGRABPropsSnapshotVC

- (instancetype)initWithUserContext:(id)userContext {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _userContext = userContext;
    _allEntries = @[];
    _visibleEntries = @[];
    _exportDocument = @{};
    self.title = @"AB Props · Native";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 82.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Código, nome, valor, expoKey ou MC";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.searchController = search;

    self.fetchButton = [[UIBarButtonItem alloc] initWithTitle:@"Fetch"
        style:UIBarButtonItemStyleDone target:self action:@selector(fetchNow)];
    if (@available(iOS 13.0, *)) {
        self.exportButton = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
            style:UIBarButtonItemStylePlain target:self action:@selector(showExportMenu:)];
    } else {
        self.exportButton = [[UIBarButtonItem alloc] initWithTitle:@"Exportar"
            style:UIBarButtonItemStylePlain target:self action:@selector(showExportMenu:)];
    }
    self.exportButton.enabled = NO;
    self.navigationItem.rightBarButtonItems = @[self.exportButton, self.fetchButton];

    UIRefreshControl *pull = [UIRefreshControl new];
    [pull addTarget:self action:@selector(reloadLocalSnapshot) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;
    [self installHeader];
    [self reloadLocalSnapshot];
}

- (void)installHeader {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 92)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = WAGRMenuSecondaryTextColor();
    label.numberOfLines = 3;
    label.text = @"Lendo o snapshot ABProps nativo da conta…";
    [container addSubview:label];
    self.statusLabel = label;

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.progress = 0.0f;
    [container addSubview:progress];
    self.progressView = progress;

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:13],
        [progress.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [progress.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
        [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:10],
    ]];
    self.tableView.tableHeaderView = container;
}

- (void)setStatus:(NSString *)status progress:(float)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status ?: @"";
        self.progressView.progress = MIN(1.0f, MAX(0.0f, progress));
    });
}

static NSString *WAGRABRedactedPayloadKey(NSString *key) {
    if (!key.length) return @"—";
    NSRange at = [key rangeOfString:@"@"]; 
    if (at.location == NSNotFound) return key;
    NSRange prefix = [key rangeOfString:@"gabp.o"];
    if (prefix.location == NSNotFound || at.location <= NSMaxRange(prefix)) return key;
    return [NSString stringWithFormat:@"%@<account>%@",
            [key substringToIndex:NSMaxRange(prefix)], [key substringFromIndex:at.location]];
}

- (void)reloadLocalSnapshot {
    NSError *error = nil;
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(&error);
    [self.refreshControl endRefreshing];
    if (!snapshot) {
        self.snapshot = nil;
        self.exportDocument = @{};
        self.allEntries = @[];
        self.visibleEntries = @[];
        self.exportButton.enabled = NO;
        self.title = @"AB Props · Native";
        [self.tableView reloadData];
        [self setStatus:error.localizedDescription ?: @"Snapshot nativo indisponível." progress:0.0f];
        return;
    }

    self.snapshot = snapshot;
    self.exportDocument = WAGRABPropsNativeExportDocument(snapshot) ?: @{};
    NSArray *entries = self.exportDocument[@"entries"];
    self.allEntries = [entries isKindOfClass:NSArray.class] ? entries : @[];
    self.exportButton.enabled = self.allEntries.count > 0;
    [self applyFilter];
    [self setStatus:[NSString stringWithFormat:@"%lu ABProps · %@ · fingerprint %@",
        (unsigned long)snapshot.numericPropCount,
        WAGRABRedactedPayloadKey(snapshot.payloadKey), snapshot.fingerprint ?: @"—"] progress:1.0f];
}

- (void)fetchNow {
    if (self.fetching) return;
    self.fetching = YES;
    self.fetchButton.enabled = NO;
    self.exportButton.enabled = NO;
    NSString *before = self.snapshot.fingerprint ?: @"";
    [self setStatus:@"Solicitando refresh pelo pipeline ABProps nativo do WhatsApp…" progress:0.08f];

    NSString *diagnostic = nil;
    BOOL invoked = WAGRABPropsTriggerNativeFetch(self.userContext, &diagnostic);
    if (!invoked) {
        self.fetching = NO;
        self.fetchButton.enabled = YES;
        self.exportButton.enabled = self.snapshot != nil;
        [self setStatus:diagnostic ?: @"Não foi possível resolver o entrypoint nativo de fetch." progress:0.0f];
        [self showAlert:@"ABProps Fetch" message:diagnostic ?: WAGRABPropsNativeDiagnosticText()];
        return;
    }

    [self setStatus:diagnostic ?: @"Fetch solicitado; aguardando atualização do cache…" progress:0.15f];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        WAGRABPropsNativeSnapshot *latest = nil;
        BOOL changed = NO;
        const NSUInteger attempts = 24;
        for (NSUInteger attempt = 0; attempt < attempts; attempt++) {
            [NSThread sleepForTimeInterval:0.5];
            latest = WAGRABPropsReadNativeSnapshot(NULL);
            NSString *fingerprint = latest.fingerprint ?: @"";
            changed = fingerprint.length && ![fingerprint isEqualToString:before];
            float fraction = 0.15f + (0.80f * ((float)(attempt + 1) / (float)attempts));
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                [self setStatus:[NSString stringWithFormat:@"Aguardando cache nativo… %lu/%lu",
                    (unsigned long)(attempt + 1), (unsigned long)attempts] progress:fraction];
            });
            if (changed) break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.fetching = NO;
            self.fetchButton.enabled = YES;
            [self reloadLocalSnapshot];
            self.exportButton.enabled = self.snapshot != nil;
            NSString *message = changed
                ? [NSString stringWithFormat:@"Cache atualizado pelo fetch nativo. Agora: %lu ABProps.",
                   (unsigned long)self.snapshot.numericPropCount]
                : [NSString stringWithFormat:@"O entrypoint foi invocado, mas o fingerprint não mudou em 12 s. O servidor pode ter respondido sem delta.\n\n%@",
                   WAGRABPropsNativeDiagnosticText()];
            [self setStatus:message progress:1.0f];
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
        self.visibleEntries = self.allEntries;
    } else {
        NSArray<NSString *> *tokens = [query componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *entry in self.allEntries) {
            NSDictionary *mc = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
                ? entry[@"mobileconfig"] : @{};
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@",
                entry[@"code"] ?: @"", entry[@"name"] ?: @"", entry[@"value"] ?: @"",
                entry[@"expoKey"] ?: @"", mc[@"local_config_index"] ?: @"",
                mc[@"parameter_index"] ?: @"", mc[@"param_specifier_hex"] ?: @""].lowercaseString;
            BOOL matches = YES;
            for (NSString *token in tokens) {
                if (token.length && ![haystack containsString:token]) { matches = NO; break; }
            }
            if (matches) [filtered addObject:entry];
        }
        self.visibleEntries = filtered;
    }
    self.title = [NSString stringWithFormat:@"AB Props (%lu)", (unsigned long)self.visibleEntries.count];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.visibleEntries.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return @"Snapshot account-scoped · gabp.*p";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Esta lista vem do cache que o próprio WhatsApp preenche após o IQ ABPROPS. Não é a seleção antiga de 51 flags e não é mc_overrides.json. Pull-to-refresh relê o AppGroup; Fetch tenta o pipeline nativo e espera o fingerprint do cache mudar.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRABNativeSnapshotCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    NSDictionary *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    NSString *name = [entry[@"name"] description] ?: @"ABProp";
    NSString *code = [entry[@"code"] description] ?: @"?";
    WAGRMenuApplyCellStyle(cell, indexPath.row, name);
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 4;
    cell.textLabel.text = name;

    NSDictionary *mc = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class] ? entry[@"mobileconfig"] : nil;
    NSString *expo = entry[@"expoKey"] ? [entry[@"expoKey"] description] : @"—";
    NSString *mcLine = mc
        ? [NSString stringWithFormat:@"MC local=%@ · p=%@ · %@",
           mc[@"local_config_index"] ?: @"?", mc[@"parameter_index"] ?: @"?",
           mc[@"param_specifier_hex"] ?: @"?"]
        : @"MC translation indisponível";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"code=%@ · value=%@ · expoKey=%@\n%@",
        code, entry[@"value"] ?: @"nil", expo, mcLine];
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.visibleEntries.count) return;
    NSDictionary *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingPrettyPrinted error:&error];
    NSString *message = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                                    : (error.localizedDescription ?: entry.description);
    [self showAlert:[NSString stringWithFormat:@"ABProp %@", entry[@"code"] ?: @"?"] message:message];
}

- (void)showExportMenu:(UIBarButtonItem *)sender {
    if (!self.snapshot) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Exportar ABProps"
        message:[NSString stringWithFormat:@"Snapshot completo: %lu propriedades.",
                 (unsigned long)self.snapshot.numericPropCount]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"JSON completo" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf exportJSON]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar diagnóstico" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = WAGRABPropsNativeDiagnosticText();
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) popover.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportJSON {
    if (!self.exportDocument.count) return;
    NSError *error = nil;
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.exportDocument options:options error:&error];
    if (!data.length) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Falha ao serializar o snapshot."];
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"whatsapp_abprops_native_snapshot.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Falha ao gravar JSON."];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                          applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) popover.barButtonItem = self.exportButton;
    [self presentViewController:activity animated:YES completion:nil];
    WAGRLogAppendF(@"[ABProps][Native] exported %@ (%lu bytes)", path, (unsigned long)data.length);
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"ABProps"
        message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { UIPasteboard.generalPasteboard.string = message ?: @""; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
