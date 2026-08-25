#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRMobileConfigSemanticPreset.h"

static void (*gWAGRMCPresetPreviousMenu)(id, SEL, UIBarButtonItem *) = NULL;

static id WAGRMCPresetKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRMCPresetAlert(UIViewController *controller,
                              NSString *title,
                              NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static NSURL *WAGRMCPresetWriteJSON(id object, NSString *filename, NSError **outError) {
    NSData *data = WAGRMobileConfigJSONData(object, outError);
    if (!data.length) return nil;
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksValidatedMC"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES attributes:nil error:outError]) return nil;
    NSString *path = [directory stringByAppendingPathComponent:filename];
    if (![data writeToFile:path options:NSDataWritingAtomic error:outError]) return nil;
    return [NSURL fileURLWithPath:path];
}

static void WAGRMCPresetGenerateAndShare(id self) {
    UIViewController *controller = (UIViewController *)self;
    NSArray<WAGRMobileConfigMapping *> *mappings = WAGRMCPresetKVC(self, @"allMappings") ?: @[];
    id context = WAGRMCPresetKVC(self, @"userContext");
    if (!mappings.count) {
        WAGRMCPresetAlert(controller, @"mc_overrides validado",
                          @"Execute primeiro o scan AB → MobileConfig para capturar o UserSession manager e resolver o crosswalk vivo.");
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *report = nil;
        NSDictionary *preset = WAGRMobileConfigInternalPresetDocument(mappings, context, &report, &error);
        NSURL *presetURL = preset ? WAGRMCPresetWriteJSON(preset, @"mc_overrides_internal_dogfood_validated.json", &error) : nil;
        NSURL *reportURL = report ? WAGRMCPresetWriteJSON(report, @"mc_overrides_internal_dogfood_validation_report.json", &error) : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!presetURL || !reportURL) {
                WAGRMCPresetAlert(controller, @"mc_overrides validado",
                    error.localizedDescription ?: @"Não foi possível gerar o preset validado.");
                return;
            }
            NSDictionary *scan = [report[@"scan"] isKindOfClass:NSDictionary.class] ? report[@"scan"] : @{};
            NSString *summary = [NSString stringWithFormat:
                @"Preset gerado com o UserSession manager.\n\nconfigs=%@\nparams=%@\nexternal IDs resolvidos=%@\nexternal==WA=%@\nmismatches=%@\nunresolved selecionados=%@\nJSON round-trip=%@\n\nO arquivo não foi gravado no container; esta ação só compartilha o preset e o relatório para validação antes de qualquer merge no mc_overrides nativo.",
                scan[@"configs"] ?: @0,
                scan[@"selected_emitted"] ?: @0,
                scan[@"external_ids_resolved"] ?: @0,
                scan[@"external_equals_wa_stable_id"] ?: @0,
                scan[@"external_mismatch_count"] ?: @0,
                scan[@"selected_unresolved"] ?: @0,
                [scan[@"json_round_trip_ok"] boolValue] ? @"YES" : @"NO"];

            UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Preset pronto"
                message:summary preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Compartilhar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                UIActivityViewController *activity = [[UIActivityViewController alloc]
                    initWithActivityItems:@[presetURL, reportURL] applicationActivities:nil];
                if (activity.popoverPresentationController) {
                    activity.popoverPresentationController.sourceView = controller.view;
                    activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), 80, 1, 1);
                }
                [controller presentViewController:activity animated:YES completion:nil];
            }]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [controller presentViewController:confirm animated:YES completion:nil];
        });
    });
}

static void WAGRMCPresetShowMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    (void)_cmd;
    UIViewController *controller = (UIViewController *)self;
    NSArray *mappings = WAGRMCPresetKVC(self, @"allMappings") ?: @[];
    id context = WAGRMCPresetKVC(self, @"userContext");
    id manager = WAGRMobileConfigContextManager(context);
    NSString *managerName = manager ? NSStringFromClass([manager class]) : @"não resolvido";

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"MobileConfig"
        message:[NSString stringWithFormat:@"manager: %@\n%lu mappings vivos\n\nO preset abaixo usa apenas external IDs retornados pelo UserSession manager e a gramática do mc_overrides físico de referência.",
                 managerName, (unsigned long)mappings.count]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Gerar preset Internal / Dogfood validado" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCPresetGenerateAndShare(self); }]];
    if (gWAGRMCPresetPreviousMenu) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Ferramentas nativas / comparação…" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                gWAGRMCPresetPreviousMenu(self, NSSelectorFromString(@"showExportMenu:"), sender);
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) sheet.popoverPresentationController.barButtonItem = sender;
    [controller presentViewController:sheet animated:YES completion:nil];
}

static void WAGRMCPresetUIInstall(void) {
    Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
    SEL selector = NSSelectorFromString(@"showExportMenu:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRMCPresetShowMenu) return;
    gWAGRMCPresetPreviousMenu = (void (*)(id, SEL, UIBarButtonItem *))current;
    method_setImplementation(method, (IMP)WAGRMCPresetShowMenu);
}

__attribute__((constructor))
static void WAGRMobileConfigSemanticPresetUICtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // WAGRMobileConfigValidatedExportPolicy installs at 1.60 s. Capture
            // that read-only native menu afterwards and layer this validated
            // generator in front of it instead of replacing the native probes.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRMCPresetUIInstall(); });
        });
    }
}
