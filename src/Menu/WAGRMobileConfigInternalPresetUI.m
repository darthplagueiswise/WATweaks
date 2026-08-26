#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigInternalPreset.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"

// Dedicated UI for the resolver-driven Internal / Employee / Dogfood preset.
// It deliberately does not replace the normal export button: the existing
// ABProps-selected export/merge remains available. This adds one native bar item
// for the semantic preset so both workflows are explicit and non-redundant.

static void (*gWAGRMCInternalOriginalViewDidLoad)(id, SEL) = NULL;
static const void *kWAGRMCInternalPresetButtonKey = &kWAGRMCInternalPresetButtonKey;

static id WAGRMCInternalKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRMCInternalAlert(UIViewController *controller,
                                NSString *title,
                                NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"MobileConfig"
            message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                UIPasteboard.generalPasteboard.string = message ?: @"";
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static NSString *WAGRMCInternalStatsText(NSDictionary *stats) {
    NSDictionary *categories = [stats[@"categories"] isKindOfClass:NSDictionary.class]
        ? stats[@"categories"] : @{};
    return [NSString stringWithFormat:
        @"Emitidos: %@\nConfigs: %@\nSelecionados semanticamente: %@\nNegativos emitidos como false: %@\nSem config stable ID UserSession: %@\nSem nomes do mapping: %@\nDeduplicados: %@\n\nCategorias:\nemployee/test: %@\ndogfood/fishfood: %@\nprivate experimentation: %@\ninternal/debug: %@\nbug report/rage shake: %@\nother internal: %@",
        stats[@"emitted"] ?: @0,
        stats[@"configs"] ?: @0,
        stats[@"semantic_selected"] ?: @0,
        stats[@"negative_polarity_false"] ?: @0,
        stats[@"skipped_unresolved_external_config_id"] ?: @0,
        stats[@"skipped_missing_id_name_mapping_names"] ?: @0,
        stats[@"deduplicated"] ?: @0,
        categories[@"employee_test"] ?: @0,
        categories[@"dogfood_fishfood"] ?: @0,
        categories[@"private_experimentation"] ?: @0,
        categories[@"internal_debug"] ?: @0,
        categories[@"bug_report_rage_shake"] ?: @0,
        categories[@"other_internal"] ?: @0];
}

static void WAGRMCInternalEnrichMapping(WAGRMobileConfigMapping *mapping, id userContext) {
    if (!mapping || !mapping.paramSpecifier) return;
    if (!mapping.externalConfigStableId) {
        uint64_t stable = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext,
                                                                      mapping.paramSpecifier);
        if (stable) mapping.externalConfigStableId = stable;
    }
    if (!mapping.configName.length || !mapping.parameterName.length) {
        NSString *fullName = WAGRMobileConfigRuntimeNameForSpecifier(mapping.paramSpecifier);
        NSString *configName = nil;
        NSString *parameterName = nil;
        WAGRMobileConfigRuntimeSplitName(fullName, &configName, &parameterName);
        if (!mapping.configName.length && configName.length) mapping.configName = configName;
        if (!mapping.parameterName.length && parameterName.length) mapping.parameterName = parameterName;
    }
}

static NSString *WAGRMCInternalStablePrefix(NSString *configKey) {
    if (![configKey isKindOfClass:NSString.class] || !configKey.length) return nil;
    if ([configKey isEqualToString:@"_qe_overrides_"]) return nil;
    NSString *prefix = [[configKey componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return nil;
    NSCharacterSet *invalid = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    return [prefix rangeOfCharacterFromSet:invalid].location == NSNotFound ? prefix : nil;
}

static NSInteger WAGRMCInternalRowIndex(NSString *row) {
    if (![row isKindOfClass:NSString.class] || !row.length) return NSNotFound;
    NSRange colon = [row rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) return NSNotFound;
    NSString *prefix = [row substringToIndex:colon.location];
    NSCharacterSet *invalid = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if ([prefix rangeOfCharacterFromSet:invalid].location != NSNotFound) return NSNotFound;
    return prefix.integerValue;
}

static NSDictionary *WAGRMCInternalMerge(NSDictionary *existing,
                                         NSDictionary *preset) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    if ([existing isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:existing];

    [preset enumerateKeysAndObjectsUsingBlock:^(NSString *newKey, id newRowsObject, __unused BOOL *stop) {
        if ([newKey isEqualToString:@"_qe_overrides_"]) return;
        if (![newRowsObject isKindOfClass:NSArray.class]) return;
        NSString *stable = WAGRMCInternalStablePrefix(newKey);
        if (!stable.length) return;

        NSString *existingKey = nil;
        for (id rawCandidate in merged.allKeys) {
            if (![rawCandidate isKindOfClass:NSString.class]) continue;
            NSString *candidate = rawCandidate;
            if ([[WAGRMCInternalStablePrefix(candidate) ?: @""] isEqualToString:stable]) {
                existingKey = candidate;
                break;
            }
        }

        // The preset is name-resolved. Prefer its canonical current mapping key;
        // rows from an older key with the same config stable ID are migrated.
        NSString *targetKey = newKey;
        NSMutableDictionary<NSNumber *, NSString *> *rowsByIndex = [NSMutableDictionary dictionary];
        NSArray *oldRows = existingKey.length && [merged[existingKey] isKindOfClass:NSArray.class]
            ? merged[existingKey] : @[];
        for (id rawRow in oldRows) {
            if (![rawRow isKindOfClass:NSString.class]) continue;
            NSInteger index = WAGRMCInternalRowIndex(rawRow);
            if (index != NSNotFound) rowsByIndex[@(index)] = rawRow;
        }
        for (id rawRow in (NSArray *)newRowsObject) {
            if (![rawRow isKindOfClass:NSString.class]) continue;
            NSInteger index = WAGRMCInternalRowIndex(rawRow);
            if (index != NSNotFound) rowsByIndex[@(index)] = rawRow;
        }

        NSArray<NSNumber *> *sorted = [rowsByIndex.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:sorted.count];
        for (NSNumber *index in sorted) {
            NSString *row = rowsByIndex[index];
            if (row.length) [rows addObject:row];
        }
        if (existingKey.length && ![existingKey isEqualToString:targetKey]) {
            [merged removeObjectForKey:existingKey];
        }
        merged[targetKey] = rows;
    }];

    // Preserve an existing QE payload exactly. The reference sentinel is added
    // only when the current file does not already contain it.
    if (!merged[@"_qe_overrides_"]) merged[@"_qe_overrides_"] = @[];
    return merged;
}

static void WAGRMCInternalBuild(id controller,
                                void (^completion)(NSDictionary *document,
                                                   NSDictionary *stats,
                                                   id userContext)) {
    NSArray<WAGRMobileConfigMapping *> *mappings =
        [WAGRMCInternalKVC(controller, @"allMappings") copy] ?: @[];
    id userContext = WAGRMCInternalKVC(controller, @"userContext");
    if (!mappings.count) {
        WAGRMCInternalAlert(controller, @"Preset Internal",
            @"Execute o scan AB → MobileConfig primeiro. O preset não usa IDs fabricados: precisa do crosswalk UserSession vivo.");
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (WAGRMobileConfigMapping *mapping in mappings) {
            @autoreleasepool { WAGRMCInternalEnrichMapping(mapping, userContext); }
        }
        NSDictionary *stats = nil;
        NSDictionary *document = WAGRMobileConfigInternalPresetDocument(mappings, &stats);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(document ?: @{}, stats ?: @{}, userContext);
        });
    });
}

static void WAGRMCInternalShareDocument(UIViewController *controller,
                                        NSDictionary *document,
                                        NSString *filename) {
    NSError *error = nil;
    NSData *data = WAGRMobileConfigInternalPresetJSONData(document, &error);
    if (!data.length) {
        WAGRMCInternalAlert(controller, @"Preset Internal",
                            error.localizedDescription ?: @"Falha ao serializar o preset.");
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksExports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:filename ?: @"mc_overrides_internal_preset.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        WAGRMCInternalAlert(controller, @"Preset Internal",
                            error.localizedDescription ?: @"Falha ao criar export temporário.");
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = controller.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), 80, 1, 1);
    }
    [controller presentViewController:activity animated:YES completion:nil];
}

static void WAGRMCInternalExport(id controller) {
    WAGRMCInternalBuild(controller, ^(NSDictionary *document, NSDictionary *stats, __unused id context) {
        if (![stats[@"emitted"] unsignedIntegerValue]) {
            WAGRMCInternalAlert(controller, @"Preset Internal não emitido", WAGRMCInternalStatsText(stats));
            return;
        }
        WAGRMCInternalShareDocument(controller, document, @"mc_overrides_internal_employee_dogfood.json");
    });
}

static void WAGRMCInternalApply(id controller) {
    WAGRMCInternalBuild(controller, ^(NSDictionary *document, NSDictionary *stats, id userContext) {
        NSUInteger emitted = [stats[@"emitted"] unsignedIntegerValue];
        if (!emitted) {
            WAGRMCInternalAlert(controller, @"Preset Internal não aplicado", WAGRMCInternalStatsText(stats));
            return;
        }
        NSString *path = WAGRMobileConfigOverridesPath(userContext);
        if (!path.length) {
            WAGRMCInternalAlert(controller, @"Preset Internal não aplicado",
                @"FBMobileConfigUserSessionContextManager não forneceu o path de mc_overrides.json. Nada foi gravado.");
            return;
        }

        NSString *summary = [NSString stringWithFormat:
            @"Mesclar %lu parâmetros resolvidos no mc_overrides.json atual?\n\nA identidade é configStableId + parameterIndex retornada pelo contexto UserSession. Entradas não pertencentes ao preset serão preservadas.\n\n%@",
            (unsigned long)emitted, WAGRMCInternalStatsText(stats)];
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Aplicar preset Internal"
            message:summary preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Aplicar" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSError *error = nil;
                    NSDictionary *existing = @{};
                    NSData *oldData = [NSData dataWithContentsOfFile:path options:0 error:&error];
                    if (oldData.length) {
                        id parsed = [NSJSONSerialization JSONObjectWithData:oldData options:0 error:&error];
                        if (![parsed isKindOfClass:NSDictionary.class]) {
                            WAGRMCInternalAlert(controller, @"mc_overrides não alterado",
                                error.localizedDescription ?: @"O arquivo existente não é um objeto JSON válido.");
                            return;
                        }
                        existing = parsed;
                    }

                    NSDictionary *merged = WAGRMCInternalMerge(existing, document);
                    NSData *newData = WAGRMobileConfigInternalPresetJSONData(merged, &error);
                    if (!newData.length) {
                        WAGRMCInternalAlert(controller, @"mc_overrides não alterado",
                            error.localizedDescription ?: @"Falha ao serializar o merge.");
                        return;
                    }

                    NSString *directory = [path stringByDeletingLastPathComponent];
                    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                                  withIntermediateDirectories:YES
                                                                   attributes:nil
                                                                        error:&error] ||
                        ![newData writeToFile:path options:NSDataWritingAtomic error:&error]) {
                        WAGRMCInternalAlert(controller, @"mc_overrides não alterado",
                            error.localizedDescription ?: @"Falha na escrita atômica.");
                        return;
                    }

                    // Re-read and parse what was physically written. This does
                    // not claim WhatsApp consumed it yet; it verifies our disk
                    // merge independently of the runtime loader.
                    NSData *verifyData = [NSData dataWithContentsOfFile:path];
                    id verify = verifyData.length
                        ? [NSJSONSerialization JSONObjectWithData:verifyData options:0 error:nil] : nil;
                    BOOL diskVerified = [verify isKindOfClass:NSDictionary.class];
                    WAGRMCInternalAlert(controller, @"Preset Internal gravado",
                        [NSString stringWithFormat:
                            @"%lu parâmetros mesclados.\nDisk JSON verificado: %@\n\n%@\n\nA confirmação de consumo pelo loader MobileConfig deve ser feita após a releitura/reinício do WhatsApp.",
                            (unsigned long)emitted, diskVerified ? @"YES" : @"NO", path]);
                });
            }]];
        [(UIViewController *)controller presentViewController:confirm animated:YES completion:nil];
    });
}

static void WAGRMCInternalShowPresetMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    (void)_cmd;
    UIViewController *controller = (UIViewController *)self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Preset Internal / Employee / Dogfood"
        message:WAGRMobileConfigInternalPresetPolicyDescription()
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Exportar preset mc_overrides" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCInternalExport(self); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Aplicar preset no mc_overrides atual" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCInternalApply(self); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Prévia / estatísticas" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            WAGRMCInternalBuild(self, ^(__unused NSDictionary *document, NSDictionary *stats, __unused id context) {
                WAGRMCInternalAlert(controller, @"Preset Internal", WAGRMCInternalStatsText(stats));
            });
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) sheet.popoverPresentationController.barButtonItem = sender;
    [controller presentViewController:sheet animated:YES completion:nil];
}

static void WAGRMCInternalViewDidLoad(id self, SEL _cmd) {
    if (gWAGRMCInternalOriginalViewDidLoad) gWAGRMCInternalOriginalViewDidLoad(self, _cmd);
    UIViewController *controller = (UIViewController *)self;
    if (objc_getAssociatedObject(controller, kWAGRMCInternalPresetButtonKey)) return;

    UIBarButtonItem *preset = nil;
    if (@available(iOS 13.0, *)) {
        preset = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"wand.and.stars"]
            style:UIBarButtonItemStylePlain target:self action:@selector(wagr_showInternalPreset:)];
        preset.accessibilityLabel = @"Preset Internal";
    } else {
        preset = [[UIBarButtonItem alloc] initWithTitle:@"Preset" style:UIBarButtonItemStylePlain
            target:self action:@selector(wagr_showInternalPreset:)];
    }
    NSMutableArray *items = [controller.navigationItem.rightBarButtonItems mutableCopy]
        ?: [NSMutableArray array];
    [items addObject:preset];
    controller.navigationItem.rightBarButtonItems = items;
    objc_setAssociatedObject(controller, kWAGRMCInternalPresetButtonKey, preset,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WAGRMCInternalInstall(void) {
    Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
    if (!cls) return;
    SEL action = NSSelectorFromString(@"wagr_showInternalPreset:");
    class_addMethod(cls, action, (IMP)WAGRMCInternalShowPresetMenu, "v@:@");

    Method load = class_getInstanceMethod(cls, @selector(viewDidLoad));
    if (!load) return;
    IMP current = method_getImplementation(load);
    if (current == (IMP)WAGRMCInternalViewDidLoad) return;
    gWAGRMCInternalOriginalViewDidLoad = (void (*)(id, SEL))current;
    method_setImplementation(load, (IMP)WAGRMCInternalViewDidLoad);
}

__attribute__((constructor))
static void WAGRMobileConfigInternalPresetUICtor(void) {
    @autoreleasepool { WAGRMCInternalInstall(); }
}
