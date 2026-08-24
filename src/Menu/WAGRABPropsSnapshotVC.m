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
    self.title = @"AB Props";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 82.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Código, getter ou param MobileConfig";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
    self.searchController = search;
    WAGRMenuApplySearchGlass(search.searchBar);

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
    [pull addTarget:self action:@selector(reloadLocalSnapshot)
      forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;

    [self installHeader];
    [self reloadLocalSnapshot];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRMenuApplySearchGlass(self.searchController.searchBar);
}

- (void)installHeader {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 64)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = WAGRMenuSecondaryTextColor();
    label.numberOfLines = 2;
    [container addSubview:label];
    self.statusLabel = label;

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.hidden = YES;
    [container addSubview:progress];
    self.progressView = progress;

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],
        [progress.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [progress.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
        [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8],
    ]];
    self.tableView.tableHeaderView = container;
}

- (void)setStatus:(NSString *)status progress:(float)progress busy:(BOOL)busy {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status ?: @"";
        self.progressView.hidden = !busy;
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
            [key substringToIndex:NSMaxRange(prefix)],
            [key substringFromIndex:at.location]];
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
        [self.tableView reloadData];
        [self setStatus:error.localizedDescription ?: @"Snapshot ABProps indisponível."
                progress:0.0f busy:NO];
        return;
    }

    self.snapshot = snapshot;
    self.exportDocument = WAGRABPropsNativeExportDocument(snapshot) ?: @{};
    NSArray *entries = self.exportDocument[@"entries"];
    self.allEntries = [entries isKindOfClass:NSArray.class] ? entries : @[];
    self.exportButton.enabled = self.allEntries.count > 0;
    [self applyFilter];

    NSDictionary *mcResolution = [self.exportDocument[@"mobileconfig_resolution"]
        isKindOfClass:NSDictionary.class] ? self.exportDocument[@"mobileconfig_resolution"] : @{};
    NSUInteger stableResolved = [mcResolution[@"config_stable_ids_resolved"] unsignedIntegerValue];
    __block NSUInteger parameterNames = 0;
    for (NSDictionary *entry in self.allEntries) {
        NSDictionary *mc = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? entry[@"mobileconfig"] : nil;
        if ([mc[@"parameter_name"] isKindOfClass:NSString.class] && [mc[@"parameter_name"] length]) {
            parameterNames++;
        }
    }

    NSString *summary = nil;
    if (stableResolved || parameterNames) {
        summary = [NSString stringWithFormat:@"%lu ABProps · %lu stable IDs · %lu param names",
            (unsigned long)snapshot.numericPropCount,
            (unsigned long)stableResolved,
            (unsigned long)parameterNames];
    } else {
        summary = [NSString stringWithFormat:@"%lu ABProps · %@",
            (unsigned long)snapshot.numericPropCount,
            WAGRABRedactedPayloadKey(snapshot.payloadKey)];
    }
    [self setStatus:summary progress:1.0f busy:NO];
}

- (void)fetchNow {
    if (self.fetching) return;
    self.fetching = YES;
    self.fetchButton.enabled = NO;
    self.exportButton.enabled = NO;

    NSString *before = self.snapshot.fingerprint ?: @"";
    [self setStatus:@"Enviando IQ ABProps pelo pipeline nativo…" progress:0.08f busy:YES];

    NSString *diagnostic = nil;
    BOOL invoked = WAGRABPropsTriggerNativeFetch(self.userContext, &diagnostic);
    if (!invoked) {
        self.fetching = NO;
        self.fetchButton.enabled = YES;
        self.exportButton.enabled = self.snapshot != nil;
        NSString *message = diagnostic ?: @"O request manager nativo não foi resolvido.";
        [self setStatus:message progress:0.0f busy:NO];
        [self showAlert:@"ABProps Fetch" message:message];
        return;
    }

    [self setStatus:@"Request ABProps enviado. Verificando se houve delta local…"
            progress:0.20f busy:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL changed = NO;
        WAGRABPropsNativeSnapshot *latest = nil;
        for (NSUInteger attempt = 0; attempt < 8; attempt++) {
            [NSThread sleepForTimeInterval:0.5];
            latest = WAGRABPropsReadNativeSnapshot(NULL);
            NSString *fingerprint = latest.fingerprint ?: @"";
            changed = fingerprint.length && ![fingerprint isEqualToString:before];
            if (changed) break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.fetching = NO;
            self.fetchButton.enabled = YES;
            [self reloadLocalSnapshot];
            self.exportButton.enabled = self.snapshot != nil;

            if (changed) {
                [self setStatus:[NSString stringWithFormat:
                    @"Fetch enviado · cache atualizado · %lu ABProps",
                    (unsigned long)self.snapshot.numericPropCount]
                        progress:1.0f busy:NO];
            } else {
                [self setStatus:@"Fetch enviado · nenhum delta local observado"
                        progress:1.0f busy:NO];
            }
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
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@ %@ %@",
                entry[@"code"] ?: @"", entry[@"name"] ?: @"", entry[@"value"] ?: @"",
                entry[@"expoKey"] ?: @"", mc[@"local_config_index"] ?: @"",
                mc[@"parameter_index"] ?: @"", mc[@"param_specifier_hex"] ?: @"",
                mc[@"config_stable_id"] ?: @"", mc[@"config_name"] ?: @"",
                mc[@"parameter_name"] ?: @""].lowercaseString;
            BOOL matches = YES;
            for (NSString *token in tokens) {
                if (token.length && ![haystack containsString:token]) {
                    matches = NO;
                    break;
                }
            }
            if (matches) [filtered addObject:entry];
        }
        self.visibleEntries = filtered;
    }
    self.title = [NSString stringWithFormat:@"AB Props (%lu)",
                  (unsigned long)self.visibleEntries.count];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.visibleEntries.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForHeaderInSection:(__unused NSInteger)section {
    return @"Snapshot da conta";
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(__unused NSInteger)section {
    return @"Fetch envia a consulta ABProps nativa. O fingerprint só muda quando o cache local recebe delta; fingerprint igual não significa falha de rede.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRABNativeSnapshotCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    NSDictionary *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    NSString *name = [entry[@"name"] description] ?: @"ABProp";
    NSString *code = [entry[@"code"] description] ?: @"?";
    WAGRMenuApplyCellStyle(cell, indexPath.row, name);
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.textLabel.text = name;

    NSDictionary *mc = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? entry[@"mobileconfig"] : nil;
    NSString *stable = mc[@"config_stable_id"] ? [mc[@"config_stable_id"] description] : nil;
    NSString *parameterName = [mc[@"parameter_name"] isKindOfClass:NSString.class]
        ? mc[@"parameter_name"] : nil;
    NSString *configName = [mc[@"config_name"] isKindOfClass:NSString.class]
        ? mc[@"config_name"] : nil;

    NSMutableString *detail = [NSMutableString stringWithFormat:@"#%@ · valor %@",
        code, entry[@"value"] ?: @"nil"];
    if (parameterName.length) {
        if (configName.length) [detail appendFormat:@"\nMC: %@.%@", configName, parameterName];
        else [detail appendFormat:@"\nMC param: %@", parameterName];
    } else if (stable.length) {
        [detail appendFormat:@" · MC %@ · p%@", stable, mc[@"parameter_index"] ?: @"?"];
    } else if (mc) {
        [detail appendFormat:@" · local %@ · p%@",
            mc[@"local_config_index"] ?: @"?", mc[@"parameter_index"] ?: @"?"];
    }
    cell.detailTextLabel.text = detail;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.visibleEntries.count) return;
    NSDictionary *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    NSString *message = data.length
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : (error.localizedDescription ?: entry.description);
    [self showAlert:[NSString stringWithFormat:@"ABProp %@", entry[@"code"] ?: @"?"]
             message:message];
}

- (void)showExportMenu:(UIBarButtonItem *)sender {
    if (!self.snapshot) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Exportar ABProps"
        message:[NSString stringWithFormat:@"Snapshot: %lu propriedades.",
                 (unsigned long)self.snapshot.numericPropCount]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"JSON completo"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf exportJSON];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar diagnóstico"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = WAGRABPropsNativeDiagnosticText();
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
        style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) popover.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportJSON {
    if (!self.exportDocument.count) return;
    NSError *error = nil;
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.exportDocument
                                                   options:options
                                                     error:&error];
    if (!data.length) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Falha ao serializar JSON."];
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
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) popover.barButtonItem = self.exportButton;
    [self presentViewController:activity animated:YES completion:nil];
    WAGRLogAppendF(@"[ABProps][Native] exported %@ (%lu bytes)",
                   path, (unsigned long)data.length);
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"ABProps"
        message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = message ?: @"";
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end