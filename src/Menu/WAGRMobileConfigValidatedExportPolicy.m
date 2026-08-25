#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRMobileConfigBridge.h"

/*
 * Binary-validation policy.
 *
 * SharedModules(4) proves that MobileConfig owns mc_overrides.json and exposes
 * FBMobileConfigContextManager -getOverridesTablePath. It also contains a
 * FBMobileConfigDebugSyncSettingsOverridesTable::saveToDisk implementation.
 * What is NOT yet proven is that WATweaks' synthetic JSON grammar is byte/
 * semantic-equivalent to that native writer. Until the native parser/writer is
 * fully reconstructed, do not offer generated mc_overrides files as if they
 * were validated. Keep only read-only/native artifacts and the crosswalk.
 */

static id WAGRMCPolicyKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRMCPolicyAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WAGRMCPolicyInvoke(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([target respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(target, selector);
}

static void WAGRMCPolicyShareNativeOverrides(UIViewController *controller, id userContext) {
    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    if (!path.length) {
        WAGRMCPolicyAlert(controller, @"mc_overrides nativo", @"getOverridesTablePath não retornou um path para este contexto.");
        return;
    }
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (!exists) {
        WAGRMCPolicyAlert(controller, @"mc_overrides nativo",
            [NSString stringWithFormat:@"O path nativo foi resolvido, mas o arquivo ainda não existe:\n\n%@", path]);
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = controller.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), 80, 1, 1);
    }
    [controller presentViewController:activity animated:YES completion:nil];
}

static void WAGRMCPolicyShowMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    (void)_cmd;
    UIViewController *controller = (UIViewController *)self;
    id userContext = WAGRMCPolicyKVC(self, @"userContext");
    NSArray *mappings = WAGRMCPolicyKVC(self, @"allMappings") ?: @[];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"MobileConfig validado"
        message:@"Geração sintética de mc_overrides está desativada até o parser/writer nativo do SharedModules(4) ser reconstruído. Estas ações não escrevem overrides."
        preferredStyle:UIAlertControllerStyleActionSheet];

    if (mappings.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Crosswalk AB → MobileConfig" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { WAGRMCPolicyInvoke(self, @"exportCrosswalk"); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Compartilhar mc_overrides nativo existente" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCPolicyShareNativeOverrides(controller, userContext); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnóstico / paths" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            WAGRMCPolicyAlert(controller, @"MobileConfig runtime", WAGRMobileConfigDiagnosticText());
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Por que a geração foi desativada?" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            WAGRMCPolicyAlert(controller, @"Validação pendente",
                @"O binário confirma mc_overrides.json, getOverridesTablePath e DebugSyncSettingsOverridesTable::saveToDisk, mas ainda não confirma que a gramática sintética usada anteriormente pelo WATweaks é idêntica ao writer nativo. Nenhuma escrita será feita até essa equivalência ser provada.");
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) sheet.popoverPresentationController.barButtonItem = sender;
    [controller presentViewController:sheet animated:YES completion:nil];
}

static void WAGRInstallMCValidatedPolicy(void) {
    Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
    SEL selector = NSSelectorFromString(@"showExportMenu:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    if (method_getImplementation(method) == (IMP)WAGRMCPolicyShowMenu) return;
    method_setImplementation(method, (IMP)WAGRMCPolicyShowMenu);
}

__attribute__((constructor))
static void WAGRMobileConfigValidatedExportPolicyCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Install after WAGRABPropsMCOverrideExportUI (1.05 s).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.60 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRInstallMCValidatedPolicy(); });
        });
    }
}
