#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"
#import "../Runtime/WAGRMobileConfigNativeEngine.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

static id WAGRMCNativeKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRMCNativeProbablyWAABSpec(NSDictionary *spec) {
    NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
    NSString *lower = className.lowercaseString;
    return [lower containsString:@"waabproperties"] ||
           [lower containsString:@"abproperties"];
}

static NSString *WAGRMCNativeValueString(id value, uint8_t nativeType) {
    if (!value || value == NSNull.null) return nil;
    switch (nativeType) {
        case 1: return [value respondsToSelector:@selector(boolValue)]
            ? ([value boolValue] ? @"true" : @"false") : nil;
        case 2: return [value respondsToSelector:@selector(longLongValue)]
            ? [NSString stringWithFormat:@"%lld", [value longLongValue]] : nil;
        case 3: return [value isKindOfClass:NSString.class] ? value : nil;
        case 4: return [value respondsToSelector:@selector(doubleValue)]
            ? [NSString stringWithFormat:@"%.17g", [value doubleValue]] : nil;
        default: return nil;
    }
}

static void WAGRMCNativeEnrichMapping(WAGRMobileConfigMapping *mapping, id userContext) {
    if (!mapping || !mapping.paramSpecifier) return;
    if (!mapping.externalConfigStableId) {
        uint64_t stable = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext,
                                                                      mapping.paramSpecifier);
        if (stable) mapping.externalConfigStableId = stable;
    }
    if (!mapping.configName.length || !mapping.parameterName.length) {
        NSString *full = WAGRMobileConfigRuntimeNameForSpecifier(mapping.paramSpecifier);
        NSString *config = nil, *parameter = nil;
        WAGRMobileConfigRuntimeSplitName(full, &config, &parameter);
        if (!mapping.configName.length && config.length) mapping.configName = config;
        if (!mapping.parameterName.length && parameter.length) mapping.parameterName = parameter;
    }
}

static NSDictionary<NSNumber *, WAGRMobileConfigMapping *> *WAGRMCNativeMappingsByWAStableID(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id userContext) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (WAGRMobileConfigMapping *mapping in mappings ?: @[]) {
        if (!mapping.waStableId) continue;
        WAGRMobileConfigMapping *old = result[@(mapping.waStableId)];
        if (!old) {
            result[@(mapping.waStableId)] = mapping;
            continue;
        }
        // Prefer the row already resolved by the exact UserSession manager.
        if (!old.externalConfigStableId && mapping.externalConfigStableId) {
            result[@(mapping.waStableId)] = mapping;
        }
    }
    for (WAGRMobileConfigMapping *mapping in result.allValues) {
        WAGRMCNativeEnrichMapping(mapping, userContext);
    }
    return result;
}

static NSDictionary *WAGRMCNativeSelectedDocument(id controller, NSDictionary **outStats) {
    NSArray<WAGRMobileConfigMapping *> *mappings = [WAGRMCNativeKVC(controller, @"allMappings") copy] ?: @[];
    id userContext = WAGRMCNativeKVC(controller, @"userContext");
    NSDictionary<NSNumber *, WAGRMobileConfigMapping *> *byWAID =
        WAGRMCNativeMappingsByWAStableID(mappings, userContext);

    NSArray<NSDictionary<NSString *, id> *> *specs = WAGRRuntimeValueAllOverrideSpecs();
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *document = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSUInteger waabSpecs = 0, idDecoded = 0, idMissing = 0, mappingMissing = 0;
    NSUInteger externalMissing = 0, unsupported = 0, emitted = 0, deduplicated = 0;

    for (NSDictionary *spec in specs) {
        if (!WAGRMCNativeProbablyWAABSpec(spec)) continue;
        waabSpecs++;
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        BOOL meta = [spec[@"meta"] boolValue];
        if (!className.length || !selector.length) { idMissing++; continue; }

        NSString *stableID = WAGRABPropsStableIDForTarget(className, selector, meta);
        if (!stableID.length) { idMissing++; continue; }
        idDecoded++;
        WAGRMobileConfigMapping *mapping = byWAID[@(stableID.longLongValue)];
        if (!mapping) { mappingMissing++; continue; }
        WAGRMCNativeEnrichMapping(mapping, userContext);
        if (!mapping.externalConfigStableId) { externalMissing++; continue; }

        id forced = WAGRRuntimeValueOverride(className, selector, meta);
        NSString *value = WAGRMCNativeValueString(forced, mapping.nativeType);
        if (!value.length) { unsupported++; continue; }

        NSString *uid = [NSString stringWithFormat:@"%llu:%u",
            mapping.externalConfigStableId, mapping.parameterIndex];
        if ([seen containsObject:uid]) { deduplicated++; continue; }
        [seen addObject:uid];

        NSString *configKey = mapping.configName.length
            ? [NSString stringWithFormat:@"%llu:%@", mapping.externalConfigStableId, mapping.configName]
            : [NSString stringWithFormat:@"%llu:", mapping.externalConfigStableId];
        NSString *row = mapping.parameterName.length
            ? [NSString stringWithFormat:@"%u: %@: %@", mapping.parameterIndex, mapping.parameterName, value]
            : [NSString stringWithFormat:@"%u: : %@", mapping.parameterIndex, value];
        NSMutableArray *rows = document[configKey];
        if (!rows) { rows = [NSMutableArray array]; document[configKey] = rows; }
        [rows addObject:row];
        emitted++;
    }

    [document enumerateKeysAndObjectsUsingBlock:^(__unused NSString *key,
                                                   NSMutableArray<NSString *> *rows,
                                                   __unused BOOL *stop) {
        [rows sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            NSInteger a = [[[left componentsSeparatedByString:@":"] firstObject] integerValue];
            NSInteger b = [[[right componentsSeparatedByString:@":"] firstObject] integerValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return [left compare:right];
        }];
    }];
    document[@"_qe_overrides_"] = [NSMutableArray array];

    if (outStats) {
        *outStats = @{
            @"persisted_override_specs": @(specs.count),
            @"waab_specs": @(waabSpecs),
            @"stable_ids_decoded_from_live_imp": @(idDecoded),
            @"stable_id_decode_missing": @(idMissing),
            @"wa_mapping_missing": @(mappingMissing),
            @"user_session_external_id_missing": @(externalMissing),
            @"unsupported_value": @(unsupported),
            @"deduplicated": @(deduplicated),
            @"emitted": @(emitted),
            @"configs": @(document.count ? document.count - 1 : 0),
            @"identity_source": @"live getter IMP stable ID -> WAMCEvaluation -> exact FBMobileConfigUserSessionContextManager",
        };
    }
    return document;
}

static void WAGRMCNativeAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WAGRMCNativeBuildSelected(id controller,
                                      void (^completion)(NSDictionary *, NSDictionary *)) {
    NSArray *mappings = WAGRMCNativeKVC(controller, @"allMappings") ?: @[];
    if (!mappings.count) {
        WAGRMCNativeAlert(controller, @"ABProps → MobileConfig",
            @"Execute o scan MobileConfig primeiro. A aplicação nativa exige o crosswalk da UserSession atual.");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *stats = nil;
        NSDictionary *document = WAGRMCNativeSelectedDocument(controller, &stats);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(document ?: @{}, stats ?: @{});
        });
    });
}

static void WAGRMCNativeShareSelected(id controller) {
    WAGRMCNativeBuildSelected(controller, ^(NSDictionary *document, NSDictionary *stats) {
        if (![stats[@"emitted"] unsignedIntegerValue]) {
            WAGRMCNativeAlert(controller, @"ABProps → MobileConfig",
                [NSString stringWithFormat:@"Nenhum override pôde ser emitido.\n\nWAAB specs=%@\nID do IMP resolvido=%@\nID do IMP ausente=%@\nMapping ausente=%@\nExternal ID ausente=%@",
                 stats[@"waab_specs"] ?: @0,
                 stats[@"stable_ids_decoded_from_live_imp"] ?: @0,
                 stats[@"stable_id_decode_missing"] ?: @0,
                 stats[@"wa_mapping_missing"] ?: @0,
                 stats[@"user_session_external_id_missing"] ?: @0]);
            return;
        }
        NSError *error = nil;
        NSData *data = WAGRMobileConfigJSONData(document, &error);
        if (!data.length) {
            WAGRMCNativeAlert(controller, @"Export", error.localizedDescription ?: @"Falha ao serializar JSON.");
            return;
        }
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [directory stringByAppendingPathComponent:@"mc_overrides_live_imp.json"];
        [data writeToFile:path options:NSDataWritingAtomic error:&error];
        if (error) { WAGRMCNativeAlert(controller, @"Export", error.localizedDescription); return; }
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        if (activity.popoverPresentationController) {
            activity.popoverPresentationController.sourceView = ((UIViewController *)controller).view;
        }
        [(UIViewController *)controller presentViewController:activity animated:YES completion:nil];
    });
}

static void WAGRMCNativeApplySelected(id controller) {
    WAGRMCNativeBuildSelected(controller, ^(NSDictionary *document, NSDictionary *stats) {
        NSUInteger emitted = [stats[@"emitted"] unsignedIntegerValue];
        if (!emitted) {
            WAGRMCNativeAlert(controller, @"Aplicar", @"Não há overrides WAAB resolvidos para aplicar.");
            return;
        }
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Aplicar pela engine nativa"
            message:[NSString stringWithFormat:
                @"Mesclar %lu parâmetros no mc_overrides da UserSession atual?\n\nA identidade foi obtida de stable IDs decodificados dos IMPs desta versão. Depois da escrita a tweak chama apenas invalidadores Objective-C ABI-safe do manager nativo; setOverrides: não é chamado porque recebe std::shared_ptr.",
                (unsigned long)emitted]
            preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Aplicar" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSError *error = nil;
                    NSString *diagnostic = nil;
                    BOOL ok = WAGRMobileConfigNativeWriteOverrideDocument(
                        document, WAGRMCNativeKVC(controller, @"userContext"), YES,
                        &error, &diagnostic);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WAGRMCNativeAlert(controller,
                            ok ? @"mc_overrides aplicado" : @"mc_overrides não alterado",
                            ok ? (diagnostic ?: @"Tabela gravada; valide o readback no Debug.")
                               : (error.localizedDescription ?: diagnostic ?: @"Falha desconhecida."));
                    });
                });
            }]];
        [(UIViewController *)controller presentViewController:confirm animated:YES completion:nil];
    });
}

static void WAGRMCNativeInvokeVoid(id controller, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([controller respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(controller, selector);
}

static void WAGRMCNativeInvokeExportMode(id controller, NSInteger mode) {
    SEL selector = NSSelectorFromString(@"exportOverridesMode:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, selector, mode);
    }
}

static void WAGRMCNativeShowExportMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    (void)_cmd;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"ABProps → MobileConfig"
        message:@"Aplicação selecionada: selector atual → stable ID do IMP → WAMCEvaluation → FBMobileConfigUserSessionContextManager → mc_overrides nativo."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak id weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:@"Aplicar Overrides ABProps · engine nativa"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id target = weakSelf; if (target) WAGRMCNativeApplySelected(target);
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Exportar Overrides ABProps · IDs do IMP"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id target = weakSelf; if (target) WAGRMCNativeShareSelected(target);
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Crosswalk completo"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id target = weakSelf; if (target) WAGRMCNativeInvokeVoid(target, @"exportCrosswalk");
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · snapshot atual"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id target = weakSelf; if (target) WAGRMCNativeInvokeExportMode(target, 0);
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · todas BOOL = true"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id target = weakSelf; if (target) WAGRMCNativeInvokeVoid(target, @"confirmAllBooleansExport");
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnóstico engine nativa"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id target = weakSelf;
            if (target) WAGRMCNativeAlert(target, @"MobileConfig native engine",
                WAGRMobileConfigNativeEngineDiagnosticText(WAGRMCNativeKVC(target, @"userContext")));
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) sheet.popoverPresentationController.barButtonItem = sender;
    [(UIViewController *)self presentViewController:sheet animated:YES completion:nil];
}

static void WAGRMCNativeInstallMenuOverride(void) {
    Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
    SEL selector = NSSelectorFromString(@"showExportMenu:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    if (method_getImplementation(method) == (IMP)WAGRMCNativeShowExportMenu) return;
    method_setImplementation(method, (IMP)WAGRMCNativeShowExportMenu);
}

__attribute__((constructor))
static void WAGRABPropsMCNativeApplyUICtor(void) {
    @autoreleasepool {
        // The older compatibility sheet installs at ~1.05 s. Install this final
        // live-IMP/UserSession sheet afterwards; no runtime catalog is built here.
        for (NSNumber *delay in @[@1.35, @2.5, @5.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ WAGRMCNativeInstallMenuOverride(); });
        }
    }
}
