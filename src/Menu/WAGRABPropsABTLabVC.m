#import "WAGRABPropsABTLabVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsABTLab.h"
#import "../Runtime/WAGRABPropsABTLiveService.h"
#import "../Runtime/WAGRLog.h"

@interface WAGRABPropsABTLabVC ()
@property(nonatomic, strong) id userContext;
@property(nonatomic, copy) NSDictionary *capabilities;
@property(nonatomic, copy) NSDictionary *document;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, assign) BOOL working;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, assign) BOOL customDeltaUpdate;
@property(nonatomic, copy) NSString *customConfigHashPolicy;
@property(nonatomic, copy) NSString *customRefreshIDPolicy;
@property(nonatomic, copy) NSString *customConfigHashValue;
@property(nonatomic, copy) NSString *customRefreshIDValue;
@property(nonatomic, assign) NSTimeInterval customTimeoutSeconds;
@end

@implementation WAGRABPropsABTLabVC

- (instancetype)initWithUserContext:(id)userContext {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"ABT Runtime Lab";
    _userContext = userContext;
    _statusText = @"Execute o preflight antes da matriz. Cada resultado registra o wire real, retries, handler e store.";
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults objectForKey:@"watweaks.abt_lab.custom.v1"];
    if (![saved isKindOfClass:NSDictionary.class]) saved = @{};
    _customDeltaUpdate = [saved[@"delta_update"] boolValue];
    _customConfigHashPolicy = [saved[@"config_hash_policy"] isKindOfClass:NSString.class]
        ? saved[@"config_hash_policy"] : @"native";
    _customRefreshIDPolicy = [saved[@"refresh_id_policy"] isKindOfClass:NSString.class]
        ? saved[@"refresh_id_policy"] : @"native";
    NSArray *policies = @[@"native", @"nil", @"empty", @"zero", @"custom"];
    if (![policies containsObject:_customConfigHashPolicy]) _customConfigHashPolicy = @"native";
    if (![policies containsObject:_customRefreshIDPolicy]) _customRefreshIDPolicy = @"native";
    _customConfigHashValue = [saved[@"custom_config_hash"] isKindOfClass:NSString.class]
        ? saved[@"custom_config_hash"] : @"";
    _customRefreshIDValue = [saved[@"custom_refresh_id"] isKindOfClass:NSString.class]
        ? saved[@"custom_refresh_id"] : @"";
    _customTimeoutSeconds = [saved[@"timeout_seconds"] doubleValue];
    if (_customTimeoutSeconds < 45.0 || _customTimeoutSeconds > 120.0) _customTimeoutSeconds = 45.0;
    return self;
}

- (NSDictionary<NSString *, id> *)customConfiguration {
    return @{
        @"label": @"ui_manual",
        @"delta_update": @(self.customDeltaUpdate),
        @"config_hash_policy": self.customConfigHashPolicy ?: @"native",
        @"refresh_id_policy": self.customRefreshIDPolicy ?: @"native",
        @"custom_config_hash": self.customConfigHashValue ?: @"",
        @"custom_refresh_id": self.customRefreshIDValue ?: @"",
        @"timeout_seconds": @(self.customTimeoutSeconds)
    };
}

- (void)saveCustomConfiguration {
    [NSUserDefaults.standardUserDefaults setObject:[self customConfiguration]
                                            forKey:@"watweaks.abt_lab.custom.v1"];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self refreshDocument];
}

- (NSString *)policyTitle:(NSString *)policy {
    NSDictionary *titles = @{
        @"native": @"Nativo do builder",
        @"nil": @"nil · omitir atributo",
        @"empty": @"String vazia",
        @"zero": @"String \"0\"",
        @"custom": @"Valor custom"
    };
    return titles[policy ?: @""] ?: policy ?: @"?";
}

- (NSString *)displayCustomValue:(NSString *)value {
    if (!value.length) return @"(vazio)";
    return value.length > 80
        ? [[value substringToIndex:80] stringByAppendingString:@"…"] : value;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 76.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
    [self refreshDocument];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDocument];
}

- (void)refreshDocument {
    self.capabilities = WAGRABPropsABTLiveCapabilityDocument(self.userContext) ?: @{};
    self.document = WAGRABPropsABTLabDocument(self.userContext) ?: @{};
    self.working = WAGRABPropsABTLabIsBusy();
    if (self.working) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 5; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;
        case 1: return 5;
        case 2: return 7;
        case 3: return 4;
        default: return 2;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Preflight ABT";
        case 1: return @"Variantes de transporte";
        case 2: return @"Wire custom em runtime";
        case 3: return @"Evidências";
        default: return @"Manutenção";
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Escopo desta build: namespace ABT. id_name_mapping.json e mc_overrides.json pertencem ao próximo checkpoint MobileConfig.";
    if (section == 1) return self.statusText;
    if (section == 2) return @"As políticas são aplicadas no initializer exato, em todos os retries e somente durante esta transação. Combinações não canônicas podem retornar erro do servidor; o erro será registrado, não mascarado.";
    if (section == 3) return @"VERIFICADO exige request exato, didSucceed, handler correlacionado, completion nativo e confirmação do WAPropertiesStore. Mudança de fingerprint é apenas evidência secundária.";
    return @"O histórico compacto persiste entre reinícios; o último resultado completo e o log pertencem à sessão atual.";
}

- (UITableViewCell *)cellForTable:(UITableView *)tableView
                        indexPath:(NSIndexPath *)indexPath
                            title:(NSString *)title
                           detail:(NSString *)detail
                             icon:(NSString *)icon
                           action:(BOOL)action {
    NSString *identifier = action ? @"WAGRABTLabAction" : @"WAGRABTLabState";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WAGRMenuApplyCellStyle(cell, indexPath.row, title);
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = WAGRMenuSymbol(icon, UIColor.whiteColor);
    cell.accessoryType = action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = action && !self.working ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = action && self.working ? WAGRMenuSecondaryTextColor() : WAGRMenuTextColor();
    return cell;
}

- (NSString *)preflightSummary {
    NSDictionary *context = [self.capabilities[@"context"] isKindOfClass:NSDictionary.class]
        ? self.capabilities[@"context"] : @{};
    NSDictionary *store = [self.capabilities[@"native_store"] isKindOfClass:NSDictionary.class]
        ? self.capabilities[@"native_store"] : @{};
    NSDictionary *gate = [self.capabilities[@"transaction_gate"] isKindOfClass:NSDictionary.class]
        ? self.capabilities[@"transaction_gate"] : @{};
    id hash = context[@"config_hash"];
    id refreshID = context[@"refresh_id"];
    NSString *gateState = [gate[@"busy"] boolValue]
        ? ([gate[@"owner_release_when_idle"] boolValue] ? @"QUARENTENA" : @"OCUPADO")
        : @"livre";
    return [NSString stringWithFormat:@"%@ · context %@ · manager %@ · WAProperties %@ · hash %@ · refreshID %@ · cache %@ props · gate %@",
        [self.capabilities[@"available"] boolValue] ? @"PRONTO" : @"INCOMPLETO",
        context[@"class"] ?: @"nil",
        [context[@"manager_resolved"] boolValue] ? @"OK" : @"nil",
        [context[@"properties_resolved"] boolValue] ? @"OK" : @"nil",
        hash && hash != NSNull.null ? @"presente" : @"nil",
        refreshID && refreshID != NSNull.null ? @"presente" : @"nil",
        store[@"prop_count"] ?: @0,
        gateState];
}

- (NSString *)latestSummary {
    NSDictionary *result = [self.document[@"latest_full_result"] isKindOfClass:NSDictionary.class]
        ? self.document[@"latest_full_result"] : @{};
    if (!result.count || [result[@"outcome"] isEqualToString:@"not_run"]) return @"Nenhuma transação executada nesta sessão.";
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"store_confirmation"] : @{};
    NSString *quarantine = [result[@"gate_quarantined_until_native_completion"] boolValue]
        ? @" · GATE EM QUARENTENA" : @"";
    return [NSString stringWithFormat:@"%@ · %@ · %@ · wire %@ props · store %@ props · attempts %lu · failures %lu · fingerprintΔ %@%@",
        [result[@"verified"] boolValue] ? @"VERIFICADO" : @"NÃO VERIFICADO",
        result[@"variant"] ?: @"?",
        result[@"outcome"] ?: @"?",
        result[@"wire_prop_count"] ?: @0,
        result[@"effective_prop_count"] ?: @0,
        (unsigned long)[result[@"wire_attempts"] count],
        (unsigned long)[result[@"did_fail_events"] count],
        [store[@"fingerprint_changed"] boolValue] ? @"YES" : @"NO",
        quarantine];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            return [self cellForTable:tableView indexPath:indexPath title:@"Estado atual"
                               detail:[self preflightSummary] icon:@"checkmark.shield.fill" action:NO];
        }
        NSDictionary *abi = [self.capabilities[@"abi"] isKindOfClass:NSDictionary.class]
            ? self.capabilities[@"abi"] : @{};
        NSUInteger exact = 0;
        for (NSDictionary *row in abi.allValues) if ([row[@"exact"] boolValue]) exact++;
        NSString *detail = [NSString stringWithFormat:@"%lu/%lu ABIs exatos · hooks instalados %@ · ativos %@ · toque para recalcular sem enviar IQ",
            (unsigned long)exact, (unsigned long)abi.count,
            [self.capabilities[@"correlation_hooks_installed"] boolValue] ? @"YES" : @"NO",
            [self.capabilities[@"correlation_hooks_active"] boolValue] ? @"YES" : @"NO"];
        return [self cellForTable:tableView indexPath:indexPath title:@"Atualizar preflight"
                           detail:detail icon:@"arrow.clockwise" action:YES];
    }

    if (indexPath.section == 1) {
        NSArray *rows = @[
            @[@"Regular · hash atual", @"deltaUpdate=NO; preserva estado e confirma o configHash efetivamente entregue ao initializer.", @"arrow.right.circle.fill"],
            @[@"Delta · refresh ID", @"deltaUpdate=YES; confirma configHash=nil e refreshID atual (ou o fallback nativo \"0\").", @"arrow.triangle.branch"],
            @[@"Full cold · sem validadores", @"O manager continua nativo; uma instrumentação transacional substitui somente configHash/refreshID por nil em todos os retries.", @"snowflake"],
            @[@"Full · hash vazio nativo", @"Executa resetConfigHashToEmptyString e depois requestFreshABProps:NO; confirma o argumento vazio no request.", @"arrow.down.circle.fill"],
            @[@"Rodar matriz completa", @"Executa as quatro formas em ordem, aguarda completion/timeout de cada uma e acumula um único relatório exportável.", @"play.rectangle.on.rectangle.fill"]
        ];
        NSArray *row = rows[(NSUInteger)indexPath.row];
        return [self cellForTable:tableView indexPath:indexPath title:row[0] detail:row[1] icon:row[2] action:YES];
    }

    if (indexPath.section == 2) {
        NSString *configSummary = [NSString stringWithFormat:@"%@ · valor %@",
            [self policyTitle:self.customConfigHashPolicy],
            [self displayCustomValue:self.customConfigHashValue]];
        NSString *refreshSummary = [NSString stringWithFormat:@"%@ · valor %@",
            [self policyTitle:self.customRefreshIDPolicy],
            [self displayCustomValue:self.customRefreshIDValue]];
        switch (indexPath.row) {
            case 0:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Branch deltaUpdate"
                   detail:self.customDeltaUpdate ? @"YES · builder usa refreshID" : @"NO · builder usa configHash"
                     icon:@"arrow.triangle.branch" action:YES];
            case 1:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Política de configHash" detail:configSummary
                     icon:@"number.square.fill" action:YES];
            case 2:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Política de refreshID" detail:refreshSummary
                     icon:@"arrow.clockwise.square.fill" action:YES];
            case 3:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Valor custom de configHash"
                   detail:[self displayCustomValue:self.customConfigHashValue]
                     icon:@"pencil" action:YES];
            case 4:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Valor custom de refreshID"
                   detail:[self displayCustomValue:self.customRefreshIDValue]
                     icon:@"pencil" action:YES];
            case 5:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Timeout"
                   detail:[NSString stringWithFormat:@"%.0f segundos · faixa segura 45–120",
                           self.customTimeoutSeconds]
                     icon:@"timer" action:YES];
            default:
                return [self cellForTable:tableView indexPath:indexPath
                    title:@"Executar wire custom"
                   detail:[NSString stringWithFormat:@"delta=%@ · configHash=%@ · refreshID=%@ · %.0fs",
                           self.customDeltaUpdate ? @"YES" : @"NO",
                           self.customConfigHashPolicy ?: @"native",
                           self.customRefreshIDPolicy ?: @"native",
                           self.customTimeoutSeconds]
                     icon:@"paperplane.fill" action:YES];
        }
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            return [self cellForTable:tableView indexPath:indexPath title:@"Último resultado"
                               detail:[self latestSummary] icon:@"waveform.path.ecg" action:NO];
        }
        if (indexPath.row == 1) {
            return [self cellForTable:tableView indexPath:indexPath title:@"Compartilhar JSON completo"
                               detail:@"Capabilities, último payload correlacionado, resultados compactos da matriz, histórico e log da sessão."
                                 icon:@"square.and.arrow.up" action:YES];
        }
        if (indexPath.row == 2) {
            return [self cellForTable:tableView indexPath:indexPath title:@"Copiar JSON"
                               detail:@"Copia o mesmo documento para a área de transferência."
                                 icon:@"doc.on.doc" action:YES];
        }
        return [self cellForTable:tableView indexPath:indexPath title:@"Abrir logs"
                           detail:@"Linha do tempo legível da sessão, incluindo tokens, variantes e outcomes."
                             icon:@"list.bullet.rectangle.portrait.fill" action:YES];
    }

    if (indexPath.row == 0) {
        NSUInteger persistent = [self.document[@"persistent_history"] count];
        NSUInteger session = [self.document[@"session_results_compact"] count];
        return [self cellForTable:tableView indexPath:indexPath title:@"Recarregar resultados"
                           detail:[NSString stringWithFormat:@"%lu nesta sessão · %lu persistidos",
                                   (unsigned long)session, (unsigned long)persistent]
                             icon:@"arrow.clockwise.circle" action:YES];
    }
    return [self cellForTable:tableView indexPath:indexPath title:@"Limpar histórico do Lab"
                       detail:@"Remove somente os resumos persistidos do laboratório; não altera gabp, hash nem overrides."
                         icon:@"trash" action:YES];
}

- (void)setWorking:(BOOL)working status:(NSString *)status {
    self.working = working;
    self.statusText = status ?: @"";
    if (working) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    [self.tableView reloadData];
}

- (void)runVariant:(NSString *)variant {
    if (self.working) return;
    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLabRunVariant(variant, self.userContext,
        ^(NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self refreshDocument];
            NSString *quarantine = [result[@"gate_quarantined_until_native_completion"] boolValue]
                ? @" · gate em quarentena; aguarde o completion ou reinicie" : @"";
            [self setWorking:NO status:[NSString stringWithFormat:@"%@ · %@ · wire=%@ · store=%@%@",
                [result[@"verified"] boolValue] ? @"VERIFICADO" : @"NÃO VERIFICADO",
                result[@"outcome"] ?: @"unknown",
                result[@"wire_prop_count"] ?: @0,
                result[@"effective_prop_count"] ?: @0,
                quarantine]];
        }, &diagnostic);
    if (!invoked) {
        [self refreshDocument];
        [self showAlert:@"ABT Runtime Lab" message:diagnostic ?: @"A variante não foi enviada."];
        return;
    }
    [self setWorking:YES status:diagnostic ?: @"Transação ABT em andamento…"];
}

- (void)runCustom {
    if (self.working) return;
    NSDictionary *configuration = [self customConfiguration];
    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLabRunCustom(configuration, self.userContext,
        ^(NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self refreshDocument];
            NSString *quarantine = [result[@"gate_quarantined_until_native_completion"] boolValue]
                ? @" · GATE EM QUARENTENA" : @"";
            [self setWorking:NO status:[NSString stringWithFormat:
                @"CUSTOM · %@ · wire=%@ · store=%@ · shape=%@%@",
                result[@"outcome"] ?: @"unknown",
                result[@"wire_prop_count"] ?: @0,
                result[@"effective_prop_count"] ?: @0,
                [result[@"wire_shape_matches_variant"] boolValue] ? @"OK" : @"MISMATCH",
                quarantine]];
        }, &diagnostic);
    if (!invoked) {
        [self refreshDocument];
        [self showAlert:@"Wire custom ABT" message:diagnostic ?: @"A transação custom não foi enviada."];
        return;
    }
    [self setWorking:YES status:diagnostic ?: @"Wire custom ABT em andamento…"];
}

- (void)chooseCustomBranch {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Branch nativo"
        message:@"Escolha o BOOL entregue a requestFreshABProps:. O builder nativo roda antes das políticas de validator."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *value in @[@NO, @YES]) {
        NSString *title = value.boolValue ? @"YES · refreshID" : @"NO · configHash";
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                weakSelf.customDeltaUpdate = value.boolValue;
                [weakSelf saveCustomConfiguration];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)choosePolicyForConfigHash:(BOOL)configHash {
    NSString *field = configHash ? @"configHash" : @"refreshID";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Política de %@", field]
        message:@"native preserva o argumento do builder; nil omite o atributo; empty/zero/custom substituem o argumento somente nesta transação."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSString *policy in @[@"native", @"nil", @"empty", @"zero", @"custom"]) {
        NSString *title = [self policyTitle:policy];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                if (configHash) weakSelf.customConfigHashPolicy = policy;
                else weakSelf.customRefreshIDPolicy = policy;
                [weakSelf saveCustomConfiguration];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editCustomValueForConfigHash:(BOOL)configHash {
    NSString *fieldName = configHash ? @"configHash" : @"refreshID";
    NSString *current = configHash ? self.customConfigHashValue : self.customRefreshIDValue;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Valor custom de %@", fieldName]
        message:@"Até 256 caracteres. O valor só é usado quando a política correspondente é custom."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current ?: @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Salvar" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *value = weakAlert.textFields.firstObject.text ?: @"";
            if (value.length > 256) {
                [weakSelf showAlert:@"Wire custom ABT" message:@"O valor excede 256 caracteres."];
                return;
            }
            if (configHash) weakSelf.customConfigHashValue = value;
            else weakSelf.customRefreshIDValue = value;
            [weakSelf saveCustomConfiguration];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseCustomTimeout {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Timeout da transação"
        message:@"O timer espera o completion exato do retry pipeline."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *seconds in @[@45, @60, @90, @120]) {
        [alert addAction:[UIAlertAction actionWithTitle:
            [NSString stringWithFormat:@"%@ segundos", seconds]
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                weakSelf.customTimeoutSeconds = seconds.doubleValue;
                [weakSelf saveCustomConfiguration];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmCustomRun {
    NSString *message = [NSString stringWithFormat:
        @"deltaUpdate=%@\nconfigHash=%@\nrefreshID=%@\ntimeout=%.0fs\n\nCombinações não canônicas podem ser rejeitadas pelo servidor; todos os retries e erros serão exportados.",
        self.customDeltaUpdate ? @"YES" : @"NO",
        [self policyTitle:self.customConfigHashPolicy],
        [self policyTitle:self.customRefreshIDPolicy],
        self.customTimeoutSeconds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Executar wire custom"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Executar" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf runCustom]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runMatrix {
    if (self.working) return;
    NSString *diagnostic = nil;
    __weak typeof(self) weakSelf = self;
    BOOL invoked = WAGRABPropsABTLabRunMatrix(self.userContext,
        ^(NSUInteger completed, NSUInteger total, NSString *variant, NSDictionary<NSString *,id> *result) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self setWorking:YES status:[NSString stringWithFormat:@"Matriz %lu/%lu · %@ · %@",
                (unsigned long)completed, (unsigned long)total, variant,
                result[@"outcome"] ?: @"unknown"]];
        }, ^(NSDictionary<NSString *,id> *document) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self refreshDocument];
            NSString *outcome = [document[@"last_matrix_outcome"] isKindOfClass:NSString.class]
                ? document[@"last_matrix_outcome"] : @"unknown";
            NSString *status = [outcome isEqualToString:@"aborted_after_timeout"]
                ? @"Matriz interrompida após timeout. O gate ficou em quarentena até o completion tardio; se ele não chegar, reinicie o WhatsApp. Exporte o JSON antes disso."
                : @"Matriz concluída. Compartilhe o JSON completo para comparar as quatro variantes.";
            [self setWorking:NO status:status];
        }, &diagnostic);
    if (!invoked) {
        [self showAlert:@"Matriz ABT" message:diagnostic ?: @"A matriz não iniciou."];
        return;
    }
    [self setWorking:YES status:diagnostic ?: @"Matriz ABT iniciada…"];
}

- (NSData *)JSONData {
    self.document = WAGRABPropsABTLabDocument(self.userContext) ?: @{};
    return [NSJSONSerialization dataWithJSONObject:self.document
                                           options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                             error:nil];
}

- (void)copyJSON {
    NSData *data = [self JSONData];
    if (!data.length) { [self showAlert:@"ABT Runtime Lab" message:@"Falha ao serializar o relatório."]; return; }
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    [self showAlert:@"ABT Runtime Lab" message:@"JSON completo copiado."];
}

- (void)shareJSON {
    NSData *data = [self JSONData];
    if (!data.length) { [self showAlert:@"ABT Runtime Lab" message:@"Falha ao serializar o relatório."]; return; }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksABTLab"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"watweaks_abt_runtime_lab.json"];
    if (![data writeToFile:path atomically:YES]) {
        [self showAlert:@"ABT Runtime Lab" message:@"Falha ao gravar o JSON temporário."];
        return;
    }
    WAGRLogAppendF(@"[ABProps][ABTLab] exported %@ bytes=%lu", path, (unsigned long)data.length);
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) popover.sourceView = self.view;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)confirmAndRunVariant:(NSString *)variant title:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Executar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf runVariant:variant];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmMatrix {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rodar matriz ABT"
        message:@"Serão enviadas quatro transações sequenciais. A matriz pode levar alguns minutos se houver retries; não feche o WhatsApp durante a execução."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Rodar 4 variantes" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf runMatrix];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearHistory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Limpar histórico"
        message:@"Isto não altera ABProps, validators nem o cache gabp."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Limpar" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        WAGRABPropsABTLabClearHistory();
        [weakSelf refreshDocument];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = message ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.working) return;
    if (indexPath.section == 0 && indexPath.row == 1) { [self refreshDocument]; return; }
    if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0: [self runVariant:WAGRABPropsABTVariantRegularHash]; return;
            case 1: [self runVariant:WAGRABPropsABTVariantDeltaRefreshID]; return;
            case 2:
                [self confirmAndRunVariant:WAGRABPropsABTVariantFullNoValidators
                    title:@"Full cold · sem validadores"
                  message:@"Esta variante ativa instrumentação somente durante a transação para enviar configHash=nil e refreshID=nil em todos os retries. O manager, conexão, parsing e store continuam nativos."];
                return;
            case 3:
                [self confirmAndRunVariant:WAGRABPropsABTVariantFullEmptyHash
                    title:@"Full · hash vazio"
                  message:@"O hash da conta será esvaziado pela API nativa antes do request. Um response verificado deve repor o hash; em caso de falha, o próximo sync nativo também tentará full."];
                return;
            default: [self confirmMatrix]; return;
        }
    }
    if (indexPath.section == 2) {
        switch (indexPath.row) {
            case 0: [self chooseCustomBranch]; return;
            case 1: [self choosePolicyForConfigHash:YES]; return;
            case 2: [self choosePolicyForConfigHash:NO]; return;
            case 3: [self editCustomValueForConfigHash:YES]; return;
            case 4: [self editCustomValueForConfigHash:NO]; return;
            case 5: [self chooseCustomTimeout]; return;
            default: [self confirmCustomRun]; return;
        }
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 1) { [self shareJSON]; return; }
        if (indexPath.row == 2) { [self copyJSON]; return; }
        if (indexPath.row == 3) {
            [self.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
        }
        return;
    }
    if (indexPath.section == 4) {
        if (indexPath.row == 0) [self refreshDocument]; else [self clearHistory];
    }
}

@end
