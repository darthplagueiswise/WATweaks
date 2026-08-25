#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "../Runtime/WAGRMobileConfigBridge.h"

/*
 * Binary-validation policy.
 *
 * SharedModules(4) proves that MobileConfig owns mc_overrides.json and exposes
 * FBMobileConfigContextManager -getOverridesTablePath. It also contains
 * FBMobileConfigStartupConfigs with +getInstance, -toJSON,
 * -configValuesOverride, -setOverrideForParam:andValue:, and a separate C++
 * FBMobileConfigDebugSyncSettingsOverridesTable::saveToDisk implementation.
 *
 * What is NOT yet proven is that WATweaks' old synthetic mc_overrides grammar
 * is equivalent to the native disk writer. Until that is reconstructed, this
 * menu is read-only: it can export the real on-disk file and native serializers
 * for comparison, but does not manufacture or write override tables.
 */

static id WAGRMCPolicyKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRMCPolicyAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message ?: @"" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = message ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WAGRMCPolicyInvoke(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([target respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL WAGRMCPolicyMethodIsObjectNoArg(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[32] = {0}; method_getReturnType(method, raw, sizeof(raw));
    const char *type = raw;
    while (*type && strchr("rnNoORV", *type)) type++;
    return *type == '@';
}

static id WAGRMCPolicyClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!WAGRMCPolicyMethodIsObjectNoArg(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRMCPolicyCallObjectNoArg(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!WAGRMCPolicyMethodIsObjectNoArg(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSData *WAGRMCPolicyDataForObject(id object) {
    if (!object || object == NSNull.null) return nil;
    if ([object isKindOfClass:NSData.class]) return object;
    if ([object isKindOfClass:NSString.class]) return [(NSString *)object dataUsingEncoding:NSUTF8StringEncoding];
    if ([NSJSONSerialization isValidJSONObject:object]) {
        return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    }
    return [[object description] dataUsingEncoding:NSUTF8StringEncoding];
}

static void WAGRMCPolicyShareData(UIViewController *controller, NSData *data, NSString *filename) {
    if (!data.length) {
        WAGRMCPolicyAlert(controller, @"Native MobileConfig", @"O objeto nativo não produziu conteúdo serializável.");
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WATweaksNativeMC"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:filename ?: @"native_mc.txt"];
    if (![data writeToFile:path atomically:YES]) {
        WAGRMCPolicyAlert(controller, @"Native MobileConfig", @"Falha ao gravar cópia temporária para compartilhamento.");
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
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = controller.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), 80, 1, 1);
    }
    [controller presentViewController:activity animated:YES completion:nil];
}

static id WAGRMCPolicyStartupConfigsInstance(void) {
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs") ?: objc_getClass("FBMobileConfigStartupConfigs");
    id instance = WAGRMCPolicyClassObjectNoArg(cls, @"getInstance");
    if (instance) return instance;
    Class old = NSClassFromString(@"FBMobileConfigStartupConfigsDeprecated") ?: objc_getClass("FBMobileConfigStartupConfigsDeprecated");
    return WAGRMCPolicyClassObjectNoArg(old, @"getInstance");
}

static void WAGRMCPolicyShareNativeStartupJSON(UIViewController *controller) {
    id startup = WAGRMCPolicyStartupConfigsInstance();
    if (!startup) {
        WAGRMCPolicyAlert(controller, @"Native StartupConfigs", @"FBMobileConfigStartupConfigs +getInstance não retornou uma instância viva.");
        return;
    }
    id json = WAGRMCPolicyCallObjectNoArg(startup, @"toJSON");
    NSData *data = WAGRMCPolicyDataForObject(json);
    WAGRMCPolicyShareData(controller, data, @"FBMobileConfigStartupConfigs-toJSON.json");
}

static void WAGRMCPolicyShareNativeOverrideDictionary(UIViewController *controller) {
    id startup = WAGRMCPolicyStartupConfigsInstance();
    if (!startup) {
        WAGRMCPolicyAlert(controller, @"Native configValuesOverride", @"FBMobileConfigStartupConfigs +getInstance não retornou uma instância viva.");
        return;
    }
    id overrides = WAGRMCPolicyCallObjectNoArg(startup, @"configValuesOverride");
    NSData *data = WAGRMCPolicyDataForObject(overrides ?: @{});
    WAGRMCPolicyShareData(controller, data, @"FBMobileConfigStartupConfigs-configValuesOverride.json");
}

static void WAGRMCPolicyCompareNativeArtifacts(UIViewController *controller, id userContext) {
    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    NSData *disk = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    id startup = WAGRMCPolicyStartupConfigsInstance();
    id nativeJSON = startup ? WAGRMCPolicyCallObjectNoArg(startup, @"toJSON") : nil;
    id nativeOverrides = startup ? WAGRMCPolicyCallObjectNoArg(startup, @"configValuesOverride") : nil;
    NSData *toJSONData = WAGRMCPolicyDataForObject(nativeJSON);
    NSData *overrideData = WAGRMCPolicyDataForObject(nativeOverrides);

    NSString *report = [NSString stringWithFormat:
        @"mc_overrides path: %@\nexists: %@\nbytes: %lu\n\nFBMobileConfigStartupConfigs: %@\n-toJSON class: %@\n-toJSON bytes: %lu\n-configValuesOverride class: %@\noverride bytes: %lu\n\nExact byte equality:\nmc_overrides == toJSON: %@\nmc_overrides == configValuesOverride serialization: %@\n\nEste teste é somente leitura; igualdade negativa não significa erro — os três artefatos podem representar camadas diferentes.",
        path ?: @"unresolved", disk.length ? @"YES" : @"NO", (unsigned long)disk.length,
        startup ? NSStringFromClass([startup class]) : @"unavailable",
        nativeJSON ? NSStringFromClass([nativeJSON class]) : @"nil", (unsigned long)toJSONData.length,
        nativeOverrides ? NSStringFromClass([nativeOverrides class]) : @"nil", (unsigned long)overrideData.length,
        (disk.length && [disk isEqualToData:toJSONData]) ? @"YES" : @"NO",
        (disk.length && [disk isEqualToData:overrideData]) ? @"YES" : @"NO"];
    WAGRMCPolicyAlert(controller, @"Native MC comparison", report);
}

static void WAGRMCPolicyShowMenu(id self, SEL _cmd, UIBarButtonItem *sender) {
    (void)_cmd;
    UIViewController *controller = (UIViewController *)self;
    id userContext = WAGRMCPolicyKVC(self, @"userContext");
    NSArray *mappings = WAGRMCPolicyKVC(self, @"allMappings") ?: @[];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"MobileConfig validado"
        message:@"Ações read-only baseadas nas APIs e paths confirmados no SharedModules(4). Geração/escrita sintética continua desativada."
        preferredStyle:UIAlertControllerStyleActionSheet];

    if (mappings.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Crosswalk AB → MobileConfig" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { WAGRMCPolicyInvoke(self, @"exportCrosswalk"); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Compartilhar mc_overrides nativo existente" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCPolicyShareNativeOverrides(controller, userContext); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Native StartupConfigs -toJSON" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCPolicyShareNativeStartupJSON(controller); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Native configValuesOverride" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCPolicyShareNativeOverrideDictionary(controller); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Comparar artefatos nativos" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { WAGRMCPolicyCompareNativeArtifacts(controller, userContext); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnóstico / paths" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            WAGRMCPolicyAlert(controller, @"MobileConfig runtime", WAGRMobileConfigDiagnosticText());
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Por que a geração foi desativada?" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            WAGRMCPolicyAlert(controller, @"Validação pendente",
                @"O binário confirma mc_overrides.json, getOverridesTablePath, FBMobileConfigStartupConfigs e DebugSyncSettingsOverridesTable::saveToDisk. Ainda falta provar que o writer C++ e o parser do arquivo usam exatamente a gramática sintética antiga do WATweaks. Até lá, nada nesta tela escreve overrides.");
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
