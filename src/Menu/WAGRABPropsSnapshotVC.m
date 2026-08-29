#import "WAGRABPropsSnapshotVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsABTLiveService.h"
#import "../Runtime/WAGRLog.h"

@interface WAGRABPropsSnapshotVC ()
@property(nonatomic, strong) id userContext;
@property(nonatomic, copy) NSDictionary *exportDocument;
@property(nonatomic, copy) NSDictionary *verifiedFetchResult;
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
    _exportDocument = @{};
    _verifiedFetchResult = @{};
    _allEntries = @[];
    _visibleEntries = @[];
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
    search.searchBar.placeholder = @"Código, getter, valor ou expoKey";
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
    [pull addTarget:self action:@selector(reloadExactLocalSnapshot)
      forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;

    [self installHeader];
    [self reloadExactLocalSnapshot];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRMenuApplySearchGlass(self.searchController.searchBar);
}

- (void)installHeader {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 72)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = WAGRMenuSecondaryTextColor();
    label.numberOfLines = 3;
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
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [progress.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [progress.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
        [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:7],
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

- (void)applyDocument:(NSDictionary *)document verifiedResult:(NSDictionary *)result {
    self.exportDocument = [document isKindOfClass:NSDictionary.class] ? document : @{};
    self.verifiedFetchResult = [result isKindOfClass:NSDictionary.class] ? result : @{};
    NSArray *entries = [self.exportDocument[@"entries"] isKindOfClass:NSArray.class]
        ? self.exportDocument[@"entries"] : @[];
    self.allEntries = entries;
    self.exportButton.enabled = entries.count > 0 && !self.fetching;
    [self applyFilter];
}

- (void)reloadExactLocalSnapshot {
    NSError *error = nil;
    NSDictionary *document = WAGRABPropsABTAccountSnapshotDocument(self.userContext, &error);
    [self.refreshControl endRefreshing];
    if (!document) {
        [self applyDocument:@{} verifiedResult:@{}];
        [self setStatus:error.localizedDescription ?: @"WAPropertiesStore exato indisponível."
                progress:0.0f busy:NO];
        return;
    }
    [self applyDocument:document verifiedResult:@{}];
    NSDictionary *store = [document[@"native_store"] isKindOfClass:NSDictionary.class]
        ? document[@"native_store"] : @{};
    [self setStatus:[NSString stringWithFormat:
        @"STORE EXATO LOCAL, ainda sem prova de server nesta sessão · %lu props · %@ · namespace %@",
        (unsigned long)self.allEntries.count, store[@"class"] ?: @"WAPropertiesStore",
        store[@"namespace"] ?: @"?"] progress:1.0f busy:NO];
}

- (void)fetchNow {
    if (self.fetching) return;
    self.fetching = YES;
    self.fetchButton.enabled = NO;
    self.exportButton.enabled = NO;
    [self setStatus:@"ABT server: full_empty_hash; aguardando IQ, handler full e store exato…"
            progress:0.08f busy:YES];

    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLiveFetchVariant(
        WAGRABPropsABTVariantFullEmptyHash, self.userContext,
        ^(NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.fetching = NO;
            self.fetchButton.enabled = YES;

            NSString *proof = nil;
            if (!WAGRABPropsABTVerifiedFullEmptyHashResult(result, &proof)) {
                self.exportButton.enabled = self.allEntries.count > 0;
                [self setStatus:proof progress:0.0f busy:NO];
                [self showAlert:@"ABT não confirmado" message:proof];
                return;
            }
            NSDictionary *document = [result[@"effective_snapshot"]
                isKindOfClass:NSDictionary.class] ? result[@"effective_snapshot"] : @{};
            [self applyDocument:document verifiedResult:result];
            [self setStatus:[NSString stringWithFormat:@"SERVER/IQ/STORE VERIFICADO · %@",
                proof ?: @""] progress:1.0f busy:NO];
        }, &diagnostic);
    if (!invoked) {
        self.fetching = NO;
        self.fetchButton.enabled = YES;
        self.exportButton.enabled = self.allEntries.count > 0;
        NSString *message = diagnostic ?: @"O request manager nativo não foi resolvido.";
        [self setStatus:message progress:0.0f busy:NO];
        [self showAlert:@"ABProps Fetch" message:message];
        return;
    }
    [self setStatus:diagnostic ?: @"full_empty_hash enviado; aguardando resposta correlacionada…"
            progress:0.20f busy:YES];
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
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                entry[@"code"] ?: @"", entry[@"name"] ?: @"", entry[@"value"] ?: @"",
                entry[@"expoKey"] ?: @""].lowercaseString;
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
    return self.verifiedFetchResult.count
        ? @"Resposta ABT confirmada nesta sessão" : @"WAPropertiesStore exato da conta";
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(__unused NSInteger)section {
    return self.verifiedFetchResult.count
        ? @"VERIFICADO exige a mesma transação: full_empty_hash, XMPPIQStanza, handler full com props, metadata/hash persistidos e contagens wire/store/snapshot idênticas."
        : @"Este conteúdo veio do WAPropertiesStore exato resolvido pelo userContext. Ele é cache local até um Fetch confirmar server → IQ → handler → store nesta sessão.";
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
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.text = name;
    NSMutableString *detail = [NSMutableString stringWithFormat:@"#%@ · valor %@",
        code, entry[@"value"] ?: @"nil"];
    if (entry[@"expoKey"]) [detail appendFormat:@"\nexpoKey %@", entry[@"expoKey"]];
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
    if (!self.exportDocument.count || self.fetching) return;
    NSString *kind = self.verifiedFetchResult.count ? @"server verificado" : @"store local exato";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Exportar ABT"
        message:[NSString stringWithFormat:@"%lu propriedades · %@ · MobileConfig excluído.",
                 (unsigned long)self.allEntries.count, kind]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"JSON ABT completo"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf exportJSON];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar prova do fetch"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSDictionary *proof = weakSelf.verifiedFetchResult.count
                ? weakSelf.verifiedFetchResult : weakSelf.exportDocument;
            NSData *data = [NSJSONSerialization dataWithJSONObject:proof
                options:NSJSONWritingPrettyPrinted error:nil];
            UIPasteboard.generalPasteboard.string = data.length
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : proof.description;
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
        style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportJSON {
    if (!self.exportDocument.count) return;
    NSError *error = nil;
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.exportDocument
                                                   options:options error:&error];
    if (!data.length) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Falha ao serializar JSON."];
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *filename = self.verifiedFetchResult.count
        ? @"whatsapp_abprops_abt_server_verified.json"
        : @"whatsapp_abprops_abt_exact_local_store.json";
    NSString *path = [directory stringByAppendingPathComponent:filename];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Falha ao gravar JSON."];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.barButtonItem = self.exportButton;
    }
    [self presentViewController:activity animated:YES completion:nil];
    WAGRLogAppendF(@"[ABProps][ABTBrowser] exported %@ (%lu bytes) verified=%@",
        path, (unsigned long)data.length, self.verifiedFetchResult.count ? @"YES" : @"NO");
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
