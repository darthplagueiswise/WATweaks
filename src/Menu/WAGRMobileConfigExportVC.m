#import "WAGRMobileConfigExportVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigNativeEngine.h"
#import "../Runtime/WAGRABPropsNativeOverrideEngine.h"
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
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(scanNow)];
    if (@available(iOS 13.0, *)) {
        self.exportButton = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
            style:UIBarButtonItemStylePlain target:self action:@selector(showExportMenu:)];
    } else {
        self.exportButton = [[UIBarButtonItem alloc]
            initWithTitle:@"Exportar" style:UIBarButtonItemStylePlain target:self action:@selector(showExportMenu:)];
    }
    self.navigationItem.rightBarButtonItems = @[self.exportButton, self.scanButton];
    [self installHeader];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.allMappings.count && !self.scanning) [self scanNow];
}

- (void)installHeader {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 110)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = WAGRMenuSecondaryTextColor();
    label.numberOfLines = 4;
    label.text = @"Schema vivo. Fetch de servidor e overrides locais são pipelines separados.";
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

#pragma mark - Mapping scan

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.scanButton.enabled = NO;
    self.exportButton.enabled = NO;
    self.title = @"Resolvendo MobileConfig…";
    [self setStatus:@"Resolvendo UserSession + WAMCEvaluation…" progress:0.0f];
    id context = self.userContext;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<WAGRMobileConfigMapping *> *mappings = WAGRMobileConfigResolveAll(context,
            ^(NSUInteger current, NSUInteger total, NSUInteger translated, NSUInteger resolved) {
                float fraction = total ? ((float)current / (float)total) : 0.0f;
                [self setStatus:[NSString stringWithFormat:@"%lu/%lu · translated=%lu · external=%lu",
                    (unsigned long)current, (unsigned long)total,
                    (unsigned long)translated, (unsigned long)resolved] progress:fraction];
            }, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.scanButton.enabled = YES;
            self.exportButton.enabled = YES;
            if (!mappings) {
                self.title = @"AB → MobileConfig";
                [self setStatus:error.localizedDescription ?: @"Falha ao resolver MobileConfig." progress:0.0f];
                [self showAlert:@"MobileConfig" message:error.localizedDescription ?: @"Falha ao resolver schema vivo."];
                return;
            }
            self.allMappings = mappings;
            NSUInteger resolved = 0;
            for (WAGRMobileConfigMapping *mapping in mappings) if (mapping.externalConfigStableId) resolved++;
            self.translatedCount = mappings.count;
            self.resolvedCount = resolved;
            [self applyFilter];
            BOOL namesLoaded = WAGRMobileConfigNamesPath(context).length &&
                [[NSFileManager defaultManager] fileExistsAtPath:WAGRMobileConfigNamesPath(context)];
            [self setStatus:[NSString stringWithFormat:@"%lu translated · %lu external IDs · native names %@",
                (unsigned long)mappings.count, (unsigned long)resolved,
                namesLoaded ? @"available" : @"not materialized"] progress:1.0f];
        });
    });
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController { [self applyFilter]; }

- (void)applyFilter {
    NSString *query = [self.searchController.searchBar.text.lowercaseString
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!query.length) {
        self.visibleMappings = self.allMappings;
    } else {
        NSArray<NSString *> *tokens = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray *filtered = [NSMutableArray array];
        for (WAGRMobileConfigMapping *mapping in self.allMappings) {
            NSString *haystack = [NSString stringWithFormat:@"%lu %llu %u %u %u %@ %@ 0x%016llx",
                (unsigned long)mapping.waStableId, mapping.externalConfigStableId,
                mapping.localConfigIndex, mapping.parameterIndex, mapping.compactParameterToken,
                mapping.configName ?: @"", mapping.parameterName ?: @"", mapping.paramSpecifier].lowercaseString;
            BOOL matches = YES;
            for (NSString *token in tokens) if (token.length && ![haystack containsString:token]) { matches = NO; break; }
            if (matches) [filtered addObject:mapping];
        }
        self.visibleMappings = filtered;
    }
    self.title = [NSString stringWithFormat:@"AB → MC (%lu)", (unsigned long)self.visibleMappings.count];
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return (NSInteger)self.visibleMappings.count; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section { return @"Live crosswalk"; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    NSDictionary *native = WAGRMobileConfigNativeEngineDiagnosticDocument(self.userContext);
    return [NSString stringWithFormat:
        @"id_name_mapping: %@\nmc_overrides (read-only): %@\nlatest config: %@\n\n"
         "ABProp overrides persist through StartupConfigs/App Group. mc_overrides.json is a separate C++ table and direct JSON writes are blocked.",
        WAGRMobileConfigNamesPath(self.userContext) ?: @"unresolved",
        WAGRMobileConfigOverridesPath(self.userContext) ?: @"unresolved",
        native[@"latest_config_path"] ?: @"unresolved"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRMobileConfigMapCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMobileConfigMapping *mapping = self.visibleMappings[(NSUInteger)indexPath.row];
    WAGRMenuApplyCellStyle(cell, indexPath.row, mapping.parameterName ?: @"mobileconfig");
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.detailTextLabel.numberOfLines = 4;
    NSString *external = mapping.externalConfigStableId ? [NSString stringWithFormat:@"%llu", mapping.externalConfigStableId] : @"unresolved";
    cell.textLabel.text = [NSString stringWithFormat:@"WA %lu → MC %@ / p%u",
        (unsigned long)mapping.waStableId, external, mapping.parameterIndex];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nconfig=%@ · local=%u · token=%u · type=%u\nspec=0x%016llx",
        mapping.parameterName ?: @"unnamed", mapping.configName ?: @"—",
        mapping.localConfigIndex, mapping.compactParameterToken, mapping.nativeType, mapping.paramSpecifier];
    cell.detailTextLabel.textColor = mapping.externalConfigStableId ? WAGRMenuSecondaryTextColor() : UIColor.systemOrangeColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.visibleMappings.count) return;
    WAGRMobileConfigMapping *mapping = self.visibleMappings[(NSUInteger)indexPath.row];
    id current = WAGRMobileConfigCurrentValue(mapping, self.userContext);
    NSString *message = [NSString stringWithFormat:
        @"WA stable ID: %lu\nparamSpecifier: 0x%016llx\nlocalConfigIndex: %u\nparameterIndex: %u\ncompact token: %u\ntype: %u\nexternal config ID: %@\nconfig: %@\nparameter: %@\neffective MC value: %@",
        (unsigned long)mapping.waStableId, mapping.paramSpecifier, mapping.localConfigIndex,
        mapping.parameterIndex, mapping.compactParameterToken, mapping.nativeType,
        mapping.externalConfigStableId ? [NSString stringWithFormat:@"%llu", mapping.externalConfigStableId] : @"unresolved",
        mapping.configName ?: @"—", mapping.parameterName ?: @"—", current ?: @"unreadable"];
    [self showAlert:@"Mapping" message:message];
}

#pragma mark - Native server fetch

- (void)fetchServerNow {
    if (self.scanning) return;
    self.scanning = YES;
    self.scanButton.enabled = NO;
    self.exportButton.enabled = NO;
    [self setStatus:@"Starting native MobileConfig fetch…" progress:0.05f];
    __weak typeof(self) weakSelf = self;
    NSString *diagnostic = nil;
    BOOL started = WAGRMobileConfigNativeFetchAccount(self.userContext, ^(NSDictionary<NSString *,id> *result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.scanning = NO;
        self.scanButton.enabled = YES;
        self.exportButton.enabled = YES;
        BOOL verified = [result[@"verified_server_response"] boolValue];
        [self setStatus:verified ? @"Server response verified; rescan schema if needed." : @"Fetch ended without verified server response." progress:1.0f];
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : [result description];
        [self showAlert:verified ? @"MobileConfig fetch ✓" : @"MobileConfig fetch" message:text ?: @""];
    }, &diagnostic);
    if (!started) {
        self.scanning = NO;
        self.scanButton.enabled = YES;
        self.exportButton.enabled = YES;
        [self setStatus:diagnostic ?: @"Native fetch could not start." progress:0.0f];
        [self showAlert:@"MobileConfig fetch" message:diagnostic ?: @"Could not start native fetch."];
    } else {
        [self setStatus:diagnostic ?: @"Native fetch started." progress:0.15f];
    }
}

#pragma mark - Export menu

- (void)showExportMenu:(UIBarButtonItem *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"MobileConfig 26.33"
        message:@"Native artifacts are read-only exports. Custom artifacts are generated separately. No action writes mc_overrides.json."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Fetch from server · native" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf fetchServerNow]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export native latest config" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf exportNativeLatestConfig]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export native id_name_mapping.json" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf shareFileAtPath:WAGRMobileConfigNamesPath(weakSelf.userContext) label:@"id_name_mapping.json"]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export native mc_overrides.json · read-only" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf shareFileAtPath:WAGRMobileConfigOverridesPath(weakSelf.userContext) label:@"mc_overrides.json"]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export native StartupConfigsOverride" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf exportJSONObject:WAGRABPropsNativeStartupOverrideStoreDocument()
                               filename:@"native_startupconfigs_overrides.json" completion:nil];
        }]];

    if (self.allMappings.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Export custom id_name_mapping / crosswalk" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf exportCrosswalk]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Export custom mc_overrides · verified ABProps only" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf exportVerifiedABPropOverrides]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Export custom MC snapshot" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf exportOverridesMode:WAGRMobileConfigOverrideExportModeCurrentSnapshot]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Export custom all BOOL=true" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf confirmAllBooleansExport]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnostics" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *text = [NSString stringWithFormat:@"%@\n\n%@",
                WAGRMobileConfigDiagnosticText(), WAGRMobileConfigNativeEngineDiagnosticText(weakSelf.userContext)];
            [weakSelf showAlert:@"MobileConfig runtime" message:text];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) popover.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportNativeLatestConfig {
    NSDictionary *diagnostic = WAGRMobileConfigNativeEngineDiagnosticDocument(self.userContext);
    NSString *path = [diagnostic[@"latest_config_path"] isKindOfClass:NSString.class] ? diagnostic[@"latest_config_path"] : nil;
    [self shareFileAtPath:path label:@"latest MobileConfig"];
}

- (void)exportCrosswalk {
    [self exportJSONObject:WAGRMobileConfigCrosswalkDocument(self.allMappings, self.userContext)
                   filename:@"whatsapp_abprop_mobileconfig_crosswalk.json" completion:nil];
}

- (void)exportVerifiedABPropOverrides {
    NSDictionary *stats = nil;
    NSDictionary *document = WAGRABPropsNativeMCOverridesExportDocument(self.userContext, &stats);
    [self exportJSONObject:document filename:@"mc_overrides_verified_abprops_custom.json" completion:^{
        [self setStatus:[NSString stringWithFormat:@"Verified ABProp custom export · %@", stats ?: @{}] progress:1.0f];
    }];
}

- (void)confirmAllBooleansExport {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom all BOOL = true"
        message:@"This is generated output only. It is not written to the native C++ overrides table."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Export" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf exportOverridesMode:WAGRMobileConfigOverrideExportModeAllBooleansTrue]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportOverridesMode:(WAGRMobileConfigOverrideExportMode)mode {
    self.exportButton.enabled = NO;
    self.scanButton.enabled = NO;
    [self setStatus:@"Reading typed account values for custom export…" progress:1.0f];
    id context = self.userContext;
    NSArray *mappings = self.allMappings;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *stats = nil;
        NSDictionary *document = WAGRMobileConfigOverrideDocument(mappings, context, mode, &stats);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exportButton.enabled = YES;
            self.scanButton.enabled = YES;
            NSString *filename = mode == WAGRMobileConfigOverrideExportModeAllBooleansTrue
                ? @"mc_overrides_all_bool_true_custom.json" : @"mc_overrides_snapshot_custom.json";
            [self exportJSONObject:document filename:filename completion:^{
                [self setStatus:[NSString stringWithFormat:@"custom export · %@", stats ?: @{}] progress:1.0f];
            }];
        });
    });
}

#pragma mark - Share helpers

- (void)shareFileAtPath:(NSString *)path label:(NSString *)label {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showAlert:@"Export" message:[NSString stringWithFormat:@"%@ is not materialized at the native path.", label ?: @"File"]];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) popover.barButtonItem = self.exportButton;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)exportJSONObject:(id)object filename:(NSString *)filename completion:(void (^ _Nullable)(void))completion {
    NSError *error = nil;
    NSData *data = WAGRMobileConfigJSONData(object, &error);
    if (!data.length) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Could not serialize JSON."];
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:filename ?: @"mobileconfig.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [self showAlert:@"Export" message:error.localizedDescription ?: @"Could not write temporary export."];
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { UIPasteboard.generalPasteboard.string = message ?: @""; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
