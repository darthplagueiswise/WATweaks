#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsCanonicalNamesV2.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

/*
 * Converts the user's persisted WAAB runtime selections into FBMobileConfig's
 * real mc_overrides grammar.
 *
 * The important invariant is that the output key is NEVER guessed from
 * localConfigIndex or from the low 16-bit compact token. It is the live result
 * of -getStableIdFromParamSpecifier: (externalConfigStableId in the current
 * compatibility model), plus the translated parameterIndex.
 */

static void (*orig_WAGRABMCShowExportMenu)(id, SEL, UIBarButtonItem *) = NULL;

static id WAGRABMCKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRABMCProbablyWAABSpec(NSDictionary *spec) {
    NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
    NSString *lower = className.lowercaseString;
    return [lower containsString:@"waabproperties"] || [lower containsString:@"abproperties"];
}

static NSString *WAGRABMCValueString(id value, uint8_t nativeType) {
    if (!value || value == NSNull.null) return nil;
    switch (nativeType) {
        case 1:
            return [value respondsToSelector:@selector(boolValue)]
                ? ([value boolValue] ? @"true" : @"false") : nil;
        case 2:
            return [value respondsToSelector:@selector(longLongValue)]
                ? [NSString stringWithFormat:@"%lld", [value longLongValue]] : nil;
        case 3:
            return [value isKindOfClass:NSString.class] ? value : nil;
        case 4:
            return [value respondsToSelector:@selector(doubleValue)]
                ? [NSString stringWithFormat:@"%.17g", [value doubleValue]] : nil;
        default:
            return nil;
    }
}

static void WAGRABMCEnrichMapping(WAGRMobileConfigMapping *mapping, id userContext) {
    if (!mapping || !mapping.paramSpecifier) return;
    if (!mapping.externalConfigStableId) {
        uint64_t stable = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext, mapping.paramSpecifier);
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

static NSDictionary<NSString *, WAGRMobileConfigMapping *> *WAGRABMCMappingBySelector(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    NSSet<NSString *> *wantedSelectors,
    id userContext) {

    if (!wantedSelectors.count || !mappings.count) return @{};
    NSMutableDictionary<NSString *, WAGRMobileConfigMapping *> *result = [NSMutableDictionary dictionary];
    for (WAGRMobileConfigMapping *mapping in mappings) {
        if (result.count == wantedSelectors.count) break;
        NSString *code = [NSString stringWithFormat:@"%lu", (unsigned long)mapping.waStableId];
        NSString *name = WAGRABPropsCanonicalNameForCode(code);
        if (!name.length || ![wantedSelectors containsObject:name]) continue;
        WAGRABMCEnrichMapping(mapping, userContext);
        // Prefer a translated/live-resolved mapping over an unresolved duplicate.
        WAGRMobileConfigMapping *old = result[name];
        if (!old || (!old.externalConfigStableId && mapping.externalConfigStableId)) result[name] = mapping;
    }
    return result;
}

static NSDictionary *WAGRABMCSelectedOverrideDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id userContext,
    NSDictionary **outStats) {

    NSArray<NSDictionary<NSString *, id> *> *specs = WAGRRuntimeValueAllOverrideSpecs();
    NSMutableArray<NSDictionary *> *waabSpecs = [NSMutableArray array];
    NSMutableSet<NSString *> *selectors = [NSMutableSet set];
    for (NSDictionary *spec in specs) {
        if (!WAGRABMCProbablyWAABSpec(spec)) continue;
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : nil;
        if (!selector.length) continue;
        [waabSpecs addObject:spec];
        [selectors addObject:selector];
    }

    NSDictionary<NSString *, WAGRMobileConfigMapping *> *bySelector =
        WAGRABMCMappingBySelector(mappings, selectors, userContext);
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *document = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *parameterUIDs = [NSMutableSet set];
    NSUInteger emitted = 0, unresolved = 0, unsupported = 0, deduplicated = 0;

    for (NSDictionary *spec in waabSpecs) {
        NSString *selector = spec[@"selector"];
        NSString *className = spec[@"class"] ?: @"";
        BOOL meta = [spec[@"meta"] boolValue];
        WAGRMobileConfigMapping *mapping = bySelector[selector];
        if (!mapping || !mapping.externalConfigStableId) { unresolved++; continue; }

        id forced = WAGRRuntimeValueOverride(className, selector, meta);
        NSString *value = WAGRABMCValueString(forced, mapping.nativeType);
        if (!value) { unsupported++; continue; }

        NSString *uid = [NSString stringWithFormat:@"%llu:%u",
            mapping.externalConfigStableId, mapping.parameterIndex];
        if ([parameterUIDs containsObject:uid]) { deduplicated++; continue; }
        [parameterUIDs addObject:uid];

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

    [document enumerateKeysAndObjectsUsingBlock:^(__unused NSString *key, NSMutableArray<NSString *> *rows, __unused BOOL *stop) {
        [rows sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            NSInteger a = [[[left componentsSeparatedByString:@":"] firstObject] integerValue];
            NSInteger b = [[[right componentsSeparatedByString:@":"] firstObject] integerValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return [left compare:right];
        }];
    }];

    if (outStats) {
        *outStats = @{
            @"persisted_runtime_overrides" : @(specs.count),
            @"waab_override_specs" : @(waabSpecs.count),
            @"selectors_mapped" : @(bySelector.count),
            @"emitted" : @(emitted),
            @"configs" : @(document.count),
            @"unresolved_live_stable_id" : @(unresolved),
            @"unsupported_value" : @(unsupported),
            @"deduplicated" : @(deduplicated),
            @"semantic_source" : @"WAMCEvaluation paramSpecifier + live FBMobileConfig user-session context manager"
        };
    }
    return document;
}

static NSString *WAGRABMCStablePrefix(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return nil;
    NSString *prefix = [[key componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return nil;
    NSCharacterSet *bad = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    return [prefix rangeOfCharacterFromSet:bad].location == NSNotFound ? prefix : nil;
}

static NSInteger WAGRABMCRowIndex(NSString *row) {
    if (![row isKindOfClass:NSString.class]) return NSNotFound;
    NSString *prefix = [[row componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return NSNotFound;
    return prefix.integerValue;
}

static NSDictionary *WAGRABMCMergeOverrideDocuments(NSDictionary *existing, NSDictionary *selected) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    if ([existing isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:existing];

    [selected enumerateKeysAndObjectsUsingBlock:^(NSString *newKey, id newRowsObject, __unused BOOL *stop) {
        if (![newRowsObject isKindOfClass:NSArray.class]) return;
        NSString *stable = WAGRABMCStablePrefix(newKey);
        if (!stable.length) return;

        NSString *oldKey = nil;
        for (NSString *candidate in merged.allKeys) {
            NSString *candidateStable = WAGRABMCStablePrefix(candidate) ?: @"";
            if ([candidateStable isEqualToString:stable]) {
                oldKey = candidate;
                break;
            }
        }
        NSString *targetKey = newKey;
        if ([newKey hasSuffix:@":"] && oldKey.length && ![oldKey hasSuffix:@":"]) targetKey = oldKey;

        NSMutableDictionary<NSNumber *, NSString *> *rowsByIndex = [NSMutableDictionary dictionary];
        NSArray *oldRows = oldKey.length && [merged[oldKey] isKindOfClass:NSArray.class] ? merged[oldKey] : @[];
        for (NSString *row in oldRows) {
            NSInteger index = WAGRABMCRowIndex(row);
            if (index != NSNotFound) rowsByIndex[@(index)] = row;
        }
        for (NSString *row in (NSArray *)newRowsObject) {
            NSInteger index = WAGRABMCRowIndex(row);
            if (index != NSNotFound) rowsByIndex[@(index)] = row;
        }

        NSArray<NSNumber *> *indices = [rowsByIndex.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:indices.count];
        for (NSNumber *index in indices) if (rowsByIndex[index]) [rows addObject:rowsByIndex[index]];
        if (oldKey.length && ![oldKey isEqualToString:targetKey]) [merged removeObjectForKey:oldKey];
        merged[targetKey] = rows;
    }];
    return merged;
}

static void WAGRABMCAlert(UIViewController *controller, NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static void WAGRABMCShareJSON(UIViewController *controller, NSDictionary *document,
                              NSString *filename, NSDictionary *stats) {
    NSError *error = nil;
    NSData *data = WAGRMobileConfigJSONData(document, &error);
    if (!data.length) {
        WAGRABMCAlert(controller, @"mc_overrides", error.localizedDescription ?: @"Falha ao serializar JSON.");
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:filename];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        WAGRABMCAlert(controller, @"mc_overrides", error.localizedDescription ?: @"Falha ao gravar export temporário.");
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = controller.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), 80, 1, 1);
    }
    [controller presentViewController:activity animated:YES completion:nil];
    (void)stats;
}

static void WAGRABMCBuildSelected(id self, void (^completion)(NSDictionary *, NSDictionary *)) {
    NSArray<WAGRMobileConfigMapping *> *mappings = [WAGRABMCKVC(self, @"allMappings") copy] ?: @[];
    id userContext = WAGRABMCKVC(self, @"userContext");
    if (!mappings.count) {
        WAGRABMCAlert(self, @"ABProps → mc_overrides", @"Execute o scan MobileConfig primeiro para resolver o contexto vivo desta conta.");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *stats = nil;
        NSDictionary *document = WAGRABMCSelectedOverrideDocument(mappings, userContext, &stats);
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(document ?: @{}, stats ?: @{}); });
    });
}

static void WAGRABMCExportSelected(id self) {
    WAGRABMCBuildSelected(self, ^(NSDictionary *document, NSDictionary *stats) {
        if (![stats[@"emitted"] unsignedIntegerValue]) {
            WAGRABMCAlert(self, @"ABProps → mc_overrides",
                [NSString stringWithFormat:@"Nenhum override WAAB pôde ser emitido.\n\nWAAB persistidos: %@\nMapeados: %@\nStable-ID não resolvido: %@\nValor incompatível: %@",
                 stats[@"waab_override_specs"] ?: @0, stats[@"selectors_mapped"] ?: @0,
                 stats[@"unresolved_live_stable_id"] ?: @0, stats[@"unsupported_value"] ?: @0]);
            return;
        }
        WAGRABMCShareJSON(self, document, @"mc_overrides_abprops_overrides.json", stats);
    });
}

static void WAGRABMCApplySelected(id self) {
    WAGRABMCBuildSelected(self, ^(NSDictionary *document, NSDictionary *stats) {
        NSUInteger emitted = [stats[@"emitted"] unsignedIntegerValue];
        if (!emitted) {
            WAGRABMCAlert(self, @"ABProps → mc_overrides", @"Não há overrides WAAB resolvidos para aplicar.");
            return;
        }
        NSString *path = WAGRMobileConfigOverridesPath(WAGRABMCKVC(self, @"userContext"));
        if (!path.length) {
            WAGRABMCAlert(self, @"ABProps → mc_overrides",
                @"O FBMobileConfig user-session context manager não forneceu getOverridesTablePath. Nada foi gravado.");
            return;
        }

        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Aplicar no mc_overrides.json"
            message:[NSString stringWithFormat:
                @"Mesclar %lu parâmetros WAAB resolvidos no arquivo MobileConfig nativo?\n\nSomente os stable IDs/parâmetros selecionados serão substituídos; o restante do arquivo é preservado. A releitura pelo WhatsApp pode exigir reinício.",
                (unsigned long)emitted]
            preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Aplicar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *error = nil;
                NSDictionary *existing = @{};
                NSData *oldData = [NSData dataWithContentsOfFile:path options:0 error:nil];
                if (oldData.length) {
                    id parsed = [NSJSONSerialization JSONObjectWithData:oldData options:0 error:&error];
                    if (![parsed isKindOfClass:NSDictionary.class]) {
                        WAGRABMCAlert(self, @"mc_overrides não alterado",
                            error.localizedDescription ?: @"O arquivo existente não é um dicionário JSON válido.");
                        return;
                    }
                    existing = parsed;
                }
                NSDictionary *merged = WAGRABMCMergeOverrideDocuments(existing, document);
                NSData *data = WAGRMobileConfigJSONData(merged, &error);
                if (!data.length) {
                    WAGRABMCAlert(self, @"mc_overrides não alterado", error.localizedDescription ?: @"Falha ao serializar merge.");
                    return;
                }
                NSString *directory = [path stringByDeletingLastPathComponent];
                if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
                    ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
                    WAGRABMCAlert(self, @"mc_overrides não alterado", error.localizedDescription ?: @"Falha ao gravar atomicamente.");
                    return;
                }
                WAGRABMCAlert(self, @"mc_overrides atualizado",
                    [NSString stringWithFormat:@"%lu parâmetros WAAB foram mesclados pelo stable ID retornado pelo manager vivo.\n\nO WhatsApp pode precisar ser reiniciado para reler a tabela de overrides.",
                     (unsigned long)emitted]);
            });
        }]];
        [(UIViewController *)self presentViewController:confirm animated:YES completion:nil];
    });
}

static void WAGRABMCInvokeVoid(id self, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([self respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(self, selector);
}

static void WAGRABMCInvokeExportMode(id self, NSInteger mode) {
    SEL selector = NSSelectorFromString(@"exportOverridesMode:");
    if ([self respondsToSelector:selector]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(self, selector, mode);
}

static void WAGRABMCShowMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    (void)_cmd;
    NSArray *mappings = WAGRABMCKVC(self, @"allMappings") ?: @[];
    if (!mappings.count) {
        if (orig_WAGRABMCShowExportMenu) orig_WAGRABMCShowExportMenu(self, _cmd, sender);
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"ABProps → MobileConfig"
        message:@"Use os overrides WAAB já escolhidos na tela para gerar ou mesclar um mc_overrides.json semanticamente equivalente. Stable ID é sempre resolvido pelo contexto MobileConfig vivo."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak id weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · Overrides ABProps" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { id target = weakSelf; if (target) WAGRABMCExportSelected(target); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Aplicar Overrides ABProps no mc_overrides" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { id target = weakSelf; if (target) WAGRABMCApplySelected(target); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Crosswalk completo" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { id target = weakSelf; if (target) WAGRABMCInvokeVoid(target, @"exportCrosswalk"); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · snapshot atual" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { id target = weakSelf; if (target) WAGRABMCInvokeExportMode(target, 0); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"mc_overrides · todas BOOL = true" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { id target = weakSelf; if (target) WAGRABMCInvokeVoid(target, @"confirmAllBooleansExport"); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnóstico / paths" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            id target = weakSelf;
            if (!target) return;
            WAGRABMCAlert(target, @"MobileConfig runtime", WAGRMobileConfigDiagnosticText());
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) sheet.popoverPresentationController.barButtonItem = sender;
    [(UIViewController *)self presentViewController:sheet animated:YES completion:nil];
}

static void WAGRABMCInstall(void) {
    Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
    SEL selector = NSSelectorFromString(@"showExportMenu:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRABMCShowMenu) return;
    orig_WAGRABMCShowExportMenu = (void (*)(id, SEL, UIBarButtonItem *))current;
    method_setImplementation(method, (IMP)WAGRABMCShowMenu);
}

__attribute__((constructor))
static void WAGRABPropsMCOverrideExportUICtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRABMCInstall(); });
        });
    }
}
