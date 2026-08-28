#import "WAGRDebugDiagnosticsVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRABPropsABTForceFull.h"
#import "../Runtime/WAGRABPropsABTLab.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigUserSessionBridge.h"
#import "../Runtime/WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

extern id WAGRCurrentUserContext(void);

@interface WAGRDebugDiagnosticsVC ()
@property(nonatomic, copy) NSDictionary<NSString *, id> *document;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, assign) BOOL working;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WAGRDebugDiagnosticsVC

static NSString *WAGRDebugMethodEncoding(Class cls, NSString *selectorName, BOOL classMethod) {
    if (!cls || !selectorName.length) return @"";
    Method method = classMethod
        ? class_getClassMethod(cls, NSSelectorFromString(selectorName))
        : class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"";
}

static NSDictionary *WAGRDebugClassSummary(NSString *className) {
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    if (!cls) return @{ @"present": @NO, @"name": className ?: @"" };

    const char *image = class_getImageName(cls);
    NSMutableDictionary *instanceMethods = [NSMutableDictionary dictionary];
    NSMutableDictionary *classMethods = [NSMutableDictionary dictionary];
    NSArray<NSString *> *selectors = @[
        @"mc", @"setMobileConfig:", @"getStableIdFromParamSpecifier:",
        @"getOverridesTablePath", @"hasValidManager", @"hasValidConfig",
        @"getBool:", @"getInt64:", @"getString:", @"getDouble:",
        @"overrides", @"setOverrides:", @"forceInvalidate",
        @"invalidateCachedLatestContext", @"forceRefreshOfConfig:",
        @"requestFreshABProps:withCompletion:",
        @"requestPropsIfNeededWithCompletionHandler:",
        @"overriddenStableIdsWithUserContext:",
        @"syncABPropsOverridesToMCWithUserContext:"
    ];
    for (NSString *selector in selectors) {
        NSString *instanceEncoding = WAGRDebugMethodEncoding(cls, selector, NO);
        if (instanceEncoding.length) instanceMethods[selector] = instanceEncoding;
        NSString *classEncoding = WAGRDebugMethodEncoding(cls, selector, YES);
        if (classEncoding.length) classMethods[selector] = classEncoding;
    }

    return @{
        @"present": @YES,
        @"name": NSStringFromClass(cls) ?: className ?: @"?",
        @"superclass": class_getSuperclass(cls) ? (NSStringFromClass(class_getSuperclass(cls)) ?: @"?") : @"nil",
        @"image": image ? ([NSString stringWithUTF8String:image] ?: @"") : @"",
        @"instance_methods": instanceMethods,
        @"class_methods": classMethods,
    };
}

static NSArray<NSString *> *WAGRDebugLoadedClassesMatchingTokens(NSArray<NSString *> *tokens,
                                                                  NSUInteger limit) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromClass(classes[index]) ?: @"";
        NSString *lower = name.lowercaseString;
        BOOL match = NO;
        for (NSString *token in tokens) {
            if ([lower containsString:token.lowercaseString]) { match = YES; break; }
        }
        if (!match) continue;
        [names addObject:name];
        if (limit && names.count >= limit) break;
    }
    free(classes);
    return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *WAGRDebugRedactedABPayloadKey(NSString *key) {
    if (!key.length) return @"";
    NSString *lower = key.lowercaseString;
    if ([lower hasPrefix:@"gabp."] && [lower hasSuffix:@"p"]) return @"gabp.<account>p";
    if ([lower hasPrefix:@"gabp."] && [lower hasSuffix:@"c"]) return @"gabp.<account>c";
    return key;
}

static NSDictionary *WAGRDebugRuntimeCatalog(NSArray<WAGRABPropEntry *> *entries,
                                             WAGRABPropsNativeSnapshot *snapshot) {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableArray *unresolved = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *types = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *images = [NSMutableDictionary dictionary];
    NSUInteger resolved = 0;

    NSDictionary *props = snapshot.props ?: @{};
    for (WAGRABPropEntry *entry in entries) {
        NSString *stableID = WAGRABPropsStableIDForTarget(entry.className,
                                                           entry.selectorName,
                                                           entry.classMethod);
        if (stableID.length) resolved++;
        else if (unresolved.count < 512) {
            [unresolved addObject:@{
                @"class": entry.className ?: @"",
                @"selector": entry.selectorName ?: @"",
                @"encoding": entry.methodEncoding ?: @"",
                @"image": entry.sourceImage ?: @"",
            }];
        }

        id serverValue = stableID.length ? props[stableID] : nil;
        NSMutableDictionary *row = [@{
            @"class": entry.className ?: @"",
            @"selector": entry.selectorName ?: @"",
            @"class_method": @(entry.classMethod),
            @"type": entry.typeCode ?: @"",
            @"type_name": entry.typeName ?: @"",
            @"encoding": entry.methodEncoding ?: @"",
            @"family": entry.categoryName ?: @"",
            @"image": entry.sourceImage ?: @"",
            @"stable_id": stableID ?: (id)NSNull.null,
        } mutableCopy];
        if (serverValue) row[@"server_cache_value"] = serverValue;
        [rows addObject:row];

        NSString *type = entry.typeName ?: entry.typeCode ?: @"?";
        types[type] = @([types[type] unsignedIntegerValue] + 1);
        NSString *image = entry.sourceImage ?: @"?";
        images[image] = @([images[image] unsignedIntegerValue] + 1);
    }

    return @{
        @"entry_count": @(entries.count),
        @"stable_id_resolved": @(resolved),
        @"stable_id_unresolved": @(entries.count - resolved),
        @"types": types,
        @"images": images,
        @"entries": rows,
        @"unresolved_sample": unresolved,
    };
}

static NSDictionary *WAGRDebugNativeSnapshotDocument(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{ @"available": @NO };
    return @{
        @"available": @YES,
        @"suite": snapshot.suiteName ?: @"",
        @"payload_key": WAGRDebugRedactedABPayloadKey(snapshot.payloadKey),
        @"metadata_key": WAGRDebugRedactedABPayloadKey(snapshot.metadataKey ?: @""),
        @"numeric_prop_count": @(snapshot.numericPropCount),
        @"fingerprint": snapshot.fingerprint ?: @"",
        @"metadata": snapshot.metadata ?: @{},
        @"props": snapshot.props ?: @{},
    };
}

static NSDictionary *WAGRDebugSelectedRuntimeClasses(void) {
    NSArray *names = @[
        @"WAProperties",
        @"WAABProperties",
        @"FOAWAABPropertiesImpl",
        @"WAMCEvaluation",
        @"XMPPConnectionABPropsRequestManager",
        @"FBMobileConfigContextManager",
        @"FBMobileConfigUserSessionContextManager",
        @"WAMobileConfigABPropsOverridesSync",
        @"WAPrivateExperimentation.PrivateABProperties",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties",
        @"PrivateExperimentationManager"
    ];
    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    for (NSString *name in names) classes[name] = WAGRDebugClassSummary(name);
    return classes;
}

static NSDictionary *WAGRDebugApplicationInfo(id context) {
    NSBundle *bundle = NSBundle.mainBundle;
    UIDevice *device = UIDevice.currentDevice;
    return @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"bundle_id": bundle.bundleIdentifier ?: @"",
        @"app_version": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"app_build": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"system_name": device.systemName ?: @"iOS",
        @"system_version": device.systemVersion ?: @"",
        @"process_os": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"context_class": context ? (NSStringFromClass([context class]) ?: @"?") : @"nil",
    };
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.title = @"Debug";
    _statusText = @"Gere um diagnóstico rápido ou profundo. O JSON pode ser compartilhado diretamente nesta conversa.";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 70.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 2; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 5 : 4;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Coleta" : @"Estado atual";
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return self.statusText;
    return @"O relatório não enumera mensagens, contatos nem credenciais. A chave gabp account-scoped é redigida; permanecem apenas IDs/valores técnicos de ABProps e metadados necessários ao diagnóstico.";
}

- (UITableViewCell *)actionCell:(UITableView *)tableView
                      indexPath:(NSIndexPath *)indexPath
                          title:(NSString *)title
                       subtitle:(NSString *)subtitle
                           icon:(NSString *)icon {
    static NSString *identifier = @"WAGRDebugActionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMenuApplyCellStyle(cell, indexPath.row, title);
    cell.textLabel.text = title;
    cell.detailTextLabel.text = subtitle;
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = WAGRMenuSymbol(icon, UIColor.whiteColor);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = self.working ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = self.working ? WAGRMenuSecondaryTextColor() : WAGRMenuTextColor();
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        switch (indexPath.row) {
            case 0: return [self actionCell:tableView indexPath:indexPath title:@"Diagnóstico rápido" subtitle:@"Runtime WAAB + stable IDs + gabp + UserSession/ABIs; não varre o domínio MobileConfig inteiro." icon:@"bolt.fill"];
            case 1: return [self actionCell:tableView indexPath:indexPath title:@"Diagnóstico profundo" subtitle:@"Inclui WAMCEvaluation → UserSession crosswalk de todo o domínio validado do build." icon:@"waveform.path.ecg"];
            case 2: return [self actionCell:tableView indexPath:indexPath title:@"Fetch ABProps ABT Full" subtitle:@"Usa resetConfigHashToEmptyString → requestFreshABProps:NO e só confirma sucesso quando o hash da conta é reposto pelo handler/store; sem hook de request." icon:@"arrow.triangle.2.circlepath"];
            case 3: return [self actionCell:tableView indexPath:indexPath title:@"Copiar JSON" subtitle:@"Copia o último relatório gerado para a área de transferência." icon:@"doc.on.doc"];
            default:return [self actionCell:tableView indexPath:indexPath title:@"Compartilhar JSON" subtitle:@"Cria watweaks_debug_runtime.json para enviar aqui." icon:@"square.and.arrow.up"];
        }
    }

    static NSString *identifier = @"WAGRDebugStateCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMenuApplyCellStyle(cell, indexPath.row, @"debug-state");
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;

    NSDictionary *doc = self.document ?: @{};
    NSDictionary *mc = [doc[@"mobileconfig_live_capture"] isKindOfClass:NSDictionary.class] ? doc[@"mobileconfig_live_capture"] : @{};
    NSDictionary *catalog = [doc[@"abprops_runtime"] isKindOfClass:NSDictionary.class] ? doc[@"abprops_runtime"] : @{};
    NSDictionary *snapshot = [doc[@"abprops_native_cache"] isKindOfClass:NSDictionary.class] ? doc[@"abprops_native_cache"] : @{};

    switch (indexPath.row) {
        case 0:
            cell.textLabel.text = @"UserSession MobileConfig";
            cell.detailTextLabel.text = [mc[@"resolved"] boolValue]
                ? [NSString stringWithFormat:@"RESOLVIDO · %@ · fonte %@", mc[@"resolved_class"] ?: @"?", mc[@"capture_source"] ?: @"?"]
                : @"Ainda não resolvido — gere um relatório para executar a captura live WAProperties.mc.";
            cell.detailTextLabel.textColor = [mc[@"resolved"] boolValue] ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
            break;
        case 1:
            cell.textLabel.text = @"WAAB runtime";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ getters · %@ IDs resolvidos · %@ sem ID",
                catalog[@"entry_count"] ?: @0, catalog[@"stable_id_resolved"] ?: @0,
                catalog[@"stable_id_unresolved"] ?: @0];
            cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
            break;
        case 2:
            cell.textLabel.text = @"Cache ABProps";
            cell.detailTextLabel.text = [snapshot[@"available"] boolValue]
                ? [NSString stringWithFormat:@"%@ props · fingerprint %@", snapshot[@"numeric_prop_count"] ?: @0, snapshot[@"fingerprint"] ?: @"?"]
                : @"gabp.*p ainda não lido neste relatório";
            cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
            break;
        default:
            cell.textLabel.text = @"Relatório";
            cell.detailTextLabel.text = self.document.count
                ? [NSString stringWithFormat:@"Gerado · schema %@ · deep=%@", self.document[@"schema"] ?: @"?", [self.document[@"deep"] boolValue] ? @"YES" : @"NO"]
                : @"Nenhum relatório gerado ainda";
            cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
            break;
    }
    return cell;
}

- (void)setWorkingStatus:(NSString *)status working:(BOOL)working {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.working = working;
        self.statusText = status ?: @"";
        if (working) [self.spinner startAnimating]; else [self.spinner stopAnimating];
        [self.tableView reloadData];
    });
}

- (NSDictionary *)buildDiagnosticDocumentDeep:(BOOL)deep {
    id context = WAGRCurrentUserContext();
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(NULL);
    NSArray *objects = WAGRABPropsResolveRuntimeObjects(context);
    NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
    NSDictionary *runtimeCatalog = WAGRDebugRuntimeCatalog(entries, snapshot);
    NSDictionary *liveMC = WAGRMobileConfigLiveCaptureDiagnosticDocument(context);

    NSMutableDictionary *document = [@{
        @"schema": @"watweaks_debug_runtime_v2",
        @"deep": @(deep),
        @"application": WAGRDebugApplicationInfo(context),
        @"abprops_runtime": runtimeCatalog,
        @"abprops_runtime_stats": WAGRABPropsCatalogStats() ?: @{},
        @"stable_id_resolver": WAGRABPropsStableIDResolverStats() ?: @{},
        @"abprops_native_cache": WAGRDebugNativeSnapshotDocument(snapshot),
        @"abprops_native_diagnostic": WAGRABPropsNativeDiagnosticText() ?: @"",
        @"abprops_abt_force_full": WAGRABPropsABTForceFullDocument() ?: @{},
        @"abprops_abt_runtime_lab": WAGRABPropsABTLabDocument(context) ?: @{},
        @"mobileconfig_live_capture": liveMC ?: @{},
        @"mobileconfig_bridge_diagnostic": WAGRMobileConfigDiagnosticText() ?: @"",
        @"mobileconfig_overrides_path": WAGRMobileConfigOverridesPath(context) ?: (id)NSNull.null,
        @"mobileconfig_names_path": WAGRMobileConfigNamesPath(context) ?: (id)NSNull.null,
        @"selected_runtime_classes": WAGRDebugSelectedRuntimeClasses(),
        @"private_experimentation_classes": WAGRDebugLoadedClassesMatchingTokens(@[@"privateexperiment", @"experimentation"], 256),
        @"mobileconfig_classes": WAGRDebugLoadedClassesMatchingTokens(@[@"mobileconfig"], 256),
        @"abprops_classes": WAGRDebugLoadedClassesMatchingTokens(@[@"abpropert", @"waab", @"wapropert"], 256),
    } mutableCopy];

    if (deep) {
        NSError *error = nil;
        NSArray<WAGRMobileConfigMapping *> *mappings = WAGRMobileConfigResolveAll(
            context,
            ^(NSUInteger current, NSUInteger total, NSUInteger translated, NSUInteger resolved) {
                if (current == total || current % 1000 == 0) {
                    [self setWorkingStatus:[NSString stringWithFormat:
                        @"Crosswalk %lu/%lu · %lu traduzidos · %lu externos",
                        (unsigned long)current, (unsigned long)total,
                        (unsigned long)translated, (unsigned long)resolved] working:YES];
                }
            }, &error);
        if (mappings) {
            document[@"mobileconfig_crosswalk"] = WAGRMobileConfigCrosswalkDocument(mappings, context) ?: @{};
            document[@"mobileconfig_mapping_count"] = @(mappings.count);
        } else {
            document[@"mobileconfig_crosswalk_error"] = error.localizedDescription ?: @"unknown";
        }
    }
    return document;
}

- (void)generateDeep:(BOOL)deep {
    if (self.working) return;
    [self setWorkingStatus:deep ? @"Gerando diagnóstico profundo…" : @"Gerando diagnóstico rápido…" working:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *document = [self buildDiagnosticDocumentDeep:deep];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.document = document ?: @{};
            [self setWorkingStatus:[NSString stringWithFormat:
                @"Concluído: %@ getters · UserSession %@.",
                self.document[@"abprops_runtime"][@"entry_count"] ?: @0,
                [self.document[@"mobileconfig_live_capture"][@"resolved"] boolValue] ? @"resolvido" : @"não resolvido"]
                              working:NO];
        });
    });
}

- (NSData *)currentJSONData {
    if (!self.document.count) return nil;
    return [NSJSONSerialization dataWithJSONObject:self.document
                                           options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                             error:nil];
}

- (void)copyJSON {
    NSData *data = [self currentJSONData];
    if (!data.length) { [self showSimpleAlert:@"Debug" message:@"Gere um diagnóstico primeiro."]; return; }
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    [self showSimpleAlert:@"Debug" message:@"JSON copiado."];
}

- (void)shareJSON {
    NSData *data = [self currentJSONData];
    if (!data.length) { [self showSimpleAlert:@"Debug" message:@"Gere um diagnóstico primeiro."]; return; }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksDebug"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"watweaks_debug_runtime.json"];
    if (![data writeToFile:path atomically:YES]) {
        [self showSimpleAlert:@"Debug" message:@"Falha ao gravar o JSON temporário."];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) popover.sourceView = self.view;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)fetchABProps {
    if (self.working) return;
    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLiveFetchForcedFull(WAGRCurrentUserContext(),
        ^(NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSMutableDictionary *document = [self.document mutableCopy] ?: [NSMutableDictionary dictionary];
            document[@"abprops_abt_force_full"] = result ?: @{};
            self.document = document;
            NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
                ? result[@"store_confirmation"] : @{};
            NSString *status = [NSString stringWithFormat:
                @"ABT full %@ · completion=%@ · hash=%@ · props=%@ · gabpΔ=%@ · %@",
                [result[@"verified"] boolValue] ? @"VERIFICADO" : @"NÃO CONFIRMADO",
                [result[@"native_completion_observed"] boolValue] ? @"YES" : @"NO",
                [store[@"config_hash_refilled"] boolValue] ? @"REFILLED" : @"EMPTY",
                store[@"effective_prop_count"] ?: @0,
                [store[@"fingerprint_changed"] boolValue] ? @"YES" : @"NO",
                result[@"outcome"] ?: @"unknown"];
            [self setWorkingStatus:status working:NO];
        }, &diagnostic);
    if (!invoked) {
        [self showSimpleAlert:@"ABProps Fetch" message:diagnostic ?: @"requestFreshABProps não foi invocado."];
        return;
    }
    [self setWorkingStatus:diagnostic ?: @"ABT full enviado; aguardando completion e hash da conta…" working:YES];
}

- (void)showSimpleAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.working || indexPath.section != 0) return;
    switch (indexPath.row) {
        case 0: [self generateDeep:NO]; break;
        case 1: [self generateDeep:YES]; break;
        case 2: [self fetchABProps]; break;
        case 3: [self copyJSON]; break;
        case 4: [self shareJSON]; break;
        default: break;
    }
}

@end
