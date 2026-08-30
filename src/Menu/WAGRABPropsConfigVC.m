#import "WAGRABPropsConfigVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRABPropsNativeOverrideEngine.h"
#import "../Runtime/WAGRLog.h"

extern id WAGRCurrentUserContext(void);

static NSString * const kWAGRABPropsPortableSchema = @"watweaks_waab_runtime_config_v1";

static void WAGRABConfigPerformOnMain(dispatch_block_t block) {
    if (!block) return;
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

static id WAGRABConfigJSONSafe(id value) {
    if (!value || value == NSNull.null) return NSNull.null;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSData.class]) return [value base64EncodedStringWithOptions:0] ?: @"";
    if ([value isKindOfClass:NSDate.class]) return @([value timeIntervalSince1970]);
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id item in (NSArray *)value) [result addObject:WAGRABConfigJSONSafe(item) ?: NSNull.null];
        return result;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, __unused BOOL *stop) {
            result[[key description] ?: @"?"] = WAGRABConfigJSONSafe(object) ?: NSNull.null;
        }];
        return result;
    }
    return [value description] ?: @"";
}

static NSString *WAGRABConfigStableString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static NSArray<NSDictionary *> *WAGRABConfigUniqueImportItems(NSArray<NSDictionary *> *items) {
    NSMutableDictionary<NSString *, NSDictionary *> *byStable = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *stable = WAGRABConfigStableString(item[@"stable_id"]);
        if (!stable.length) continue;
        if (!byStable[stable]) [order addObject:stable];
        byStable[stable] = item;
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *stable in order) [result addObject:byStable[stable]];
    return result;
}

typedef NS_ENUM(NSInteger, WAGRABConfigImportMode) {
    WAGRABConfigImportModeOverridesOnly = 0,
    WAGRABConfigImportModeFullSnapshot,
};

@interface WAGRABPropsConfigVC ()
@property(nonatomic, strong, nullable) id userContext;
@property(nonatomic, assign) BOOL working;
@end

@implementation WAGRABPropsConfigVC

- (instancetype)initWithUserContext:(id)userContext {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _userContext = userContext;
    self.title = @"ABProps Config";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return 2;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return @"Configuração WAAB portátil";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"O export lê getters WAAB efetivos, ABI, imagem, stable ID e overrides. O import nunca edita gabp.*p nem mc_overrides.json: ele revalida o stable ID nesta build e usa StartupConfigs com readback.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRABConfigCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRABConfigCell"];
    WAGRMenuApplyCellStyle(cell, indexPath.row, indexPath.row == 0 ? @"abprops-export" : @"abprops-import");
    if (indexPath.row == 0) {
        cell.textLabel.text = @"Exportar configuração ABProps atual";
        cell.detailTextLabel.text = @"Snapshot tipado de todos os getters vivos, incluindo valores não alocados no cache ABT.";
        cell.imageView.image = WAGRMenuSymbol(@"square.and.arrow.up", nil);
    } else {
        cell.textLabel.text = @"Importar configuração ABProps";
        cell.detailTextLabel.text = @"Restaura somente overrides ou, com confirmação explícita, aplica o snapshot efetivo completo.";
        cell.imageView.image = WAGRMenuSymbol(@"square.and.arrow.down", nil);
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = self.working ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.working) return;
    if (indexPath.row == 0) [self exportCurrentConfiguration];
    else [self chooseImportDocument];
}

- (void)setWorkingState:(BOOL)working {
    self.working = working;
    if (working) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }
    [self.tableView reloadData];
}

- (id)resolvedUserContext {
    return self.userContext ?: WAGRCurrentUserContext();
}

- (void)exportCurrentConfiguration {
    id context = [self resolvedUserContext];
    if (!context) {
        [self showAlert:@"Export falhou" message:@"O userContext account-scoped ainda não foi capturado."];
        return;
    }
    [self setWorkingState:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // WAAB getters are account-scoped application code. Resolve the object
        // graph and invoke every getter on the main thread, then serialize/write
        // the already-sanitized snapshot off-main. Build 580 did the inverse;
        // it invoked a false-positive -[WAPropertiesStore init] on a global QoS
        // queue and crashed in SharedModules with SIGTRAP.
        __block NSArray *objects = nil;
        __block NSArray<WAGRABPropEntry *> *entries = nil;
        WAGRABConfigPerformOnMain(^{
            objects = WAGRABPropsResolveRuntimeObjects(context);
            entries = WAGRABPropsScan(objects);
        });
        NSDictionary *tracked = WAGRABPropsNativeTrackedOverrides();
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:entries.count];
        NSUInteger stableCount = 0;
        NSUInteger importableCount = 0;

        for (WAGRABPropEntry *entry in entries) {
            NSString *stable = entry.stableID;
            if (stable.length) stableCount++;
            __block NSString *display = nil;
            __block id safeValue = nil;
            WAGRABConfigPerformOnMain(^{
                id rawValue = nil;
                display = WAGRABPropsCurrentValue(entry, objects, &rawValue);
                safeValue = WAGRABConfigJSONSafe(rawValue ?: display ?: NSNull.null);
            });
            BOOL importable = stable.length && safeValue != NSNull.null &&
                ([safeValue isKindOfClass:NSString.class] || [safeValue isKindOfClass:NSNumber.class] ||
                 [safeValue isKindOfClass:NSArray.class] || [safeValue isKindOfClass:NSDictionary.class]);
            if (importable) importableCount++;
            id overrideValue = stable.length ? tracked[stable] : nil;
            [rows addObject:@{
                @"stable_id" : stable ?: NSNull.null,
                @"selector" : entry.selectorName ?: @"",
                @"class" : entry.className ?: @"",
                @"class_method" : @(entry.classMethod),
                @"type" : entry.typeCode ?: @"?",
                @"encoding" : entry.methodEncoding ?: @"",
                @"image" : entry.sourceImage ?: @"",
                @"effective_value" : safeValue ?: NSNull.null,
                @"effective_display" : display ?: @"",
                @"importable" : @(importable),
                @"override_present" : @(overrideValue != nil),
                @"override_value" : overrideValue ? WAGRABConfigJSONSafe(overrideValue) : NSNull.null,
            }];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSComparisonResult bySelector = [left[@"selector"] localizedCaseInsensitiveCompare:right[@"selector"]];
            return bySelector != NSOrderedSame ? bySelector : [left[@"class"] localizedCaseInsensitiveCompare:right[@"class"]];
        }];

        NSDictionary *document = @{
            @"schema" : kWAGRABPropsPortableSchema,
            @"created_at" : @((long long)NSDate.date.timeIntervalSince1970),
            @"app_version" : NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
            @"build" : NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"",
            @"entry_count" : @(rows.count),
            @"stable_id_count" : @(stableCount),
            @"importable_count" : @(importableCount),
            @"tracked_override_count" : @(tracked.count),
            @"entries" : rows,
        };
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:document
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        NSURL *url = nil;
        if (data.length) {
            NSString *name = [NSString stringWithFormat:@"WhatsApp-ABProps-%lld.json", (long long)NSDate.date.timeIntervalSince1970];
            url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
            if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) url = nil;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            [self setWorkingState:NO];
            if (!url) {
                [self showAlert:@"Export falhou" message:error.localizedDescription ?: @"Não foi possível gerar o JSON."];
                return;
            }
            WAGRLogAppendF(@"[ABPropsConfig] export entries=%lu stable=%lu importable=%lu overrides=%lu",
                (unsigned long)rows.count, (unsigned long)stableCount,
                (unsigned long)importableCount, (unsigned long)tracked.count);
            UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            if (activity.popoverPresentationController) {
                activity.popoverPresentationController.sourceView = self.view;
                activity.popoverPresentationController.sourceRect = self.view.bounds;
            }
            [self presentViewController:activity animated:YES completion:nil];
        });
    });
}

- (void)chooseImportDocument {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.json", @"public.text"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSError *error = nil;
    id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    NSDictionary *document = [object isKindOfClass:NSDictionary.class] ? object : nil;
    NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class] ? document[@"entries"] : nil;
    if (!document || ![document[@"schema"] isEqual:kWAGRABPropsPortableSchema] || !entries) {
        [self showAlert:@"Import falhou" message:error.localizedDescription ?: @"Arquivo não usa o schema WAAB Runtime Config v1."];
        return;
    }

    NSString *summary = [NSString stringWithFormat:@"Arquivo: %@.%@\nEntradas: %@\nStable IDs: %@\nOverrides exportados: %@",
        document[@"app_version"] ?: @"?", document[@"build"] ?: @"?",
        document[@"entry_count"] ?: @(entries.count), document[@"stable_id_count"] ?: @0,
        document[@"tracked_override_count"] ?: @0];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Importar ABProps"
        message:summary preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restaurar somente overrides" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf importDocument:document mode:WAGRABConfigImportModeOverridesOnly];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Aplicar snapshot completo" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf confirmFullSnapshotImport:document];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmFullSnapshotImport:(NSDictionary *)document {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Forçar snapshot completo?"
        message:@"Isto transforma todos os valores importáveis do arquivo em overrides persistentes. O preflight bloqueia qualquer stable ID incompatível, mas a mudança é deliberadamente ampla."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Aplicar tudo" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf importDocument:document mode:WAGRABConfigImportModeFullSnapshot];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importDocument:(NSDictionary *)document mode:(WAGRABConfigImportMode)mode {
    id context = [self resolvedUserContext];
    if (!context) {
        [self showAlert:@"Import falhou" message:@"O userContext account-scoped ainda não foi capturado."];
        return;
    }
    NSArray *sourceEntries = [document[@"entries"] isKindOfClass:NSArray.class] ? document[@"entries"] : @[];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (id object in sourceEntries) {
        NSDictionary *entry = [object isKindOfClass:NSDictionary.class] ? object : nil;
        if (!entry || ![entry[@"importable"] boolValue]) continue;
        id value = nil;
        if (mode == WAGRABConfigImportModeOverridesOnly) {
            if (![entry[@"override_present"] boolValue]) continue;
            value = entry[@"override_value"];
        } else {
            value = entry[@"effective_value"];
        }
        if (!value || value == NSNull.null) continue;
        NSMutableDictionary *item = [entry mutableCopy];
        item[@"import_value"] = value;
        [candidates addObject:item];
    }
    NSArray<NSDictionary *> *items = WAGRABConfigUniqueImportItems(candidates);
    if (!items.count && mode == WAGRABConfigImportModeFullSnapshot) {
        [self showAlert:@"Import falhou" message:@"Nenhuma entrada importável foi encontrada."];
        return;
    }

    [self setWorkingState:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *preflightFailures = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *validated = [NSMutableArray array];
        for (NSDictionary *item in items) {
            NSString *className = [item[@"class"] isKindOfClass:NSString.class] ? item[@"class"] : @"";
            NSString *selector = [item[@"selector"] isKindOfClass:NSString.class] ? item[@"selector"] : @"";
            NSString *exportedStable = WAGRABConfigStableString(item[@"stable_id"]);
            BOOL classMethod = [item[@"class_method"] boolValue];
            __block NSString *currentStable = nil;
            __block NSString *mappingDiagnostic = nil;
            __block NSDictionary *mapping = nil;
            WAGRABConfigPerformOnMain(^{
                currentStable = WAGRABPropsStableIDForTarget(className, selector, classMethod);
                mapping = currentStable.length
                    ? WAGRABPropsNativeOverrideMapping(currentStable, context, &mappingDiagnostic) : nil;
            });
            if (!exportedStable.length || ![currentStable isEqualToString:exportedStable] || !mapping) {
                if (preflightFailures.count < 40) {
                    [preflightFailures addObject:[NSString stringWithFormat:@"%@.%@: arquivo=%@ runtime=%@ (%@)",
                        className, selector, exportedStable ?: @"nil", currentStable ?: @"nil", mappingDiagnostic ?: @"mapping ausente"]];
                }
                continue;
            }
            [validated addObject:item];
        }

        NSDictionary *before = WAGRABPropsNativeTrackedOverrides();
        NSMutableArray<NSString *> *changed = [NSMutableArray array];
        NSMutableArray<NSString *> *writeFailures = [NSMutableArray array];
        if (!preflightFailures.count) {
            for (NSDictionary *item in validated) {
                NSString *stable = WAGRABConfigStableString(item[@"stable_id"]);
                __block NSError *error = nil;
                __block NSString *diagnostic = nil;
                __block BOOL wrote = NO;
                WAGRABConfigPerformOnMain(^{
                    wrote = WAGRABPropsNativeSetOverride(stable, item[@"import_value"],
                                                         context, &error, &diagnostic);
                });
                if (wrote) {
                    [changed addObject:stable];
                } else {
                    [writeFailures addObject:[NSString stringWithFormat:@"%@ (AB %@): %@", item[@"selector"], stable, error.localizedDescription ?: diagnostic ?: @"falhou"]];
                    break;
                }
            }
        }

        if (preflightFailures.count || writeFailures.count) {
            for (NSString *stable in changed.reverseObjectEnumerator) {
                id previous = before[stable];
                WAGRABConfigPerformOnMain(^{
                    if (previous) WAGRABPropsNativeSetOverride(stable, previous, context, NULL, NULL);
                    else WAGRABPropsNativeClearOverride(stable, context, NULL, NULL);
                });
            }
        }

        NSMutableArray<NSString *> *clearFailures = [NSMutableArray array];
        NSUInteger cleared = 0;
        if (!preflightFailures.count && !writeFailures.count && mode == WAGRABConfigImportModeOverridesOnly) {
            NSMutableSet<NSString *> *wanted = [NSMutableSet set];
            for (NSDictionary *item in validated) {
                NSString *stable = WAGRABConfigStableString(item[@"stable_id"]);
                if (stable.length) [wanted addObject:stable];
            }
            for (NSString *stable in before) {
                if ([wanted containsObject:stable]) continue;
                __block NSError *error = nil;
                __block NSString *diagnostic = nil;
                __block BOOL didClear = NO;
                WAGRABConfigPerformOnMain(^{
                    didClear = WAGRABPropsNativeClearOverride(stable, context, &error, &diagnostic);
                });
                if (didClear) cleared++;
                else if (clearFailures.count < 40) [clearFailures addObject:[NSString stringWithFormat:@"AB %@: %@", stable, error.localizedDescription ?: diagnostic ?: @"falhou"]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            [self setWorkingState:NO];
            if (preflightFailures.count) {
                [self showAlert:@"Import bloqueado no preflight"
                        message:[NSString stringWithFormat:@"Nenhuma escrita foi feita. %lu vínculos class/selector/stable-ID são incompatíveis.\n\n%@", (unsigned long)preflightFailures.count, [preflightFailures componentsJoinedByString:@"\n"]]];
            } else if (writeFailures.count) {
                [self showAlert:@"Import revertido"
                        message:[NSString stringWithFormat:@"A escrita falhou e %lu mudanças anteriores foram revertidas.\n\n%@", (unsigned long)changed.count, [writeFailures componentsJoinedByString:@"\n"]]];
            } else {
                WAGRLogAppendF(@"[ABPropsConfig] import mode=%ld applied=%lu cleared=%lu clearFailures=%lu",
                    (long)mode, (unsigned long)changed.count, (unsigned long)cleared, (unsigned long)clearFailures.count);
                NSString *extra = clearFailures.count ? [NSString stringWithFormat:@"\n\nFalhas ao limpar overrides antigos:\n%@", [clearFailures componentsJoinedByString:@"\n"]] : @"";
                [self showAlert:@"Import concluído"
                        message:[NSString stringWithFormat:@"Aplicados: %lu\nOverrides antigos removidos: %lu%@", (unsigned long)changed.count, (unsigned long)cleared, extra]];
            }
        });
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
