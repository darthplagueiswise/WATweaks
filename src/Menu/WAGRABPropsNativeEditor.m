#import "WAGRABPropsNativeEditor.h"
#import "../Runtime/WAGRABPropsNativeOverrideEngine.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

#include <stdlib.h>

static NSString *WAGRABNativeValueFromRow(NSString *row) {
    if (![row isKindOfClass:NSString.class] || !row.length) return nil;
    NSRange first = [row rangeOfString:@":"];
    if (first.location == NSNotFound) return nil;
    NSRange rest = NSMakeRange(NSMaxRange(first), row.length - NSMaxRange(first));
    NSRange second = [row rangeOfString:@":" options:0 range:rest];
    if (second.location == NSNotFound) return nil;
    NSString *value = [row substringFromIndex:NSMaxRange(second)];
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void WAGRABNativeShowResult(UIViewController *presenter,
                                   NSString *title,
                                   BOOL success,
                                   NSError *error,
                                   NSString *diagnostic,
                                   dispatch_block_t completion) {
    NSString *message = success ? (diagnostic ?: @"Aplicado pelo MobileConfig nativo em memória.")
                                : (error.localizedDescription ?: diagnostic ?: @"Falha ao aplicar override nativo.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (completion) completion();
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@interface WAGRABPropsNativeTextEditorVC : UIViewController
@property(nonatomic, copy) NSString *stableID;
@property(nonatomic, strong) id userContext;
@property(nonatomic, copy) dispatch_block_t completion;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation WAGRABPropsNativeTextEditorVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = [NSString stringWithFormat:@"AB %@ · STRING/JSON", self.stableID ?: @"?"];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone
        target:self action:@selector(applyNative)];

    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    text.autocorrectionType = UITextAutocorrectionTypeNo;
    text.autocapitalizationType = UITextAutocapitalizationTypeNone;
    text.smartQuotesType = UITextSmartQuotesTypeNo;
    text.smartDashesType = UITextSmartDashesTypeNo;
    text.layer.cornerRadius = 14.0;
    text.layer.masksToBounds = YES;
    text.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.textView = text;

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    status.textColor = UIColor.secondaryLabelColor;
    status.numberOfLines = 0;
    status.text = @"Aplicar usa FBMobileConfigStartupConfigs em memória e invalida o contexto MobileConfig. A persistência física em mc_overrides.json continua desativada até o serializer nativo ser comprovado; não instala swizzle WAAB.";
    self.statusLabel = status;

    [self.view addSubview:text];
    [self.view addSubview:status];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [text.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [status.topAnchor constraintEqualToAnchor:text.bottomAnchor constant:10],
        [status.leadingAnchor constraintEqualToAnchor:text.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:text.trailingAnchor],
        [status.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [text.heightAnchor constraintGreaterThanOrEqualToConstant:250],
    ]];
}

- (void)applyNative {
    NSError *error = nil;
    NSString *diagnostic = nil;
    BOOL ok = WAGRABPropsNativeSetOverride(self.stableID, self.textView.text ?: @"",
                                            self.userContext, &error, &diagnostic);
    self.statusLabel.text = ok ? (diagnostic ?: @"Aplicado.")
                               : (error.localizedDescription ?: diagnostic ?: @"Falha.");
    if (ok && self.completion) self.completion();
}

@end

static void WAGRABNativeConfigurePopover(UIAlertController *alert, UIView *sourceView) {
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (!popover) return;
    UIView *view = sourceView ?: alert.view;
    popover.sourceView = view;
    popover.sourceRect = view.bounds;
}

static NSNumber *WAGRABNativeParseInteger(NSString *text, BOOL *ok) {
    if (ok) *ok = NO;
    const char *bytes = text.UTF8String;
    if (!bytes || !*bytes) return nil;
    char *end = NULL;
    long long value = strtoll(bytes, &end, 10);
    if (end == bytes || (end && *end != '\0')) return nil;
    if (ok) *ok = YES;
    return @(value);
}

static NSNumber *WAGRABNativeParseDouble(NSString *text, BOOL *ok) {
    if (ok) *ok = NO;
    const char *bytes = text.UTF8String;
    if (!bytes || !*bytes) return nil;
    char *end = NULL;
    double value = strtod(bytes, &end);
    if (end == bytes || (end && *end != '\0')) return nil;
    if (ok) *ok = YES;
    return @(value);
}

void WAGRPresentABPropsNativeEditor(UIViewController *presenter,
                                    UIView *sourceView,
                                    WAGRABPropEntry *entry,
                                    NSArray *runtimeObjects,
                                    id userContext,
                                    NSString *stableIDHint,
                                    dispatch_block_t runtimeFallback,
                                    dispatch_block_t completion) {
    if (!presenter || !entry) return;

    NSString *stableID = stableIDHint.length ? stableIDHint :
        WAGRABPropsStableIDForTarget(entry.className, entry.selectorName, entry.classMethod);
    if (!stableID.length) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ABProp sem stable ID comprovado"
            message:@"O getter atual não foi correlacionado com um WA stable ID. WATweaks não vai fingir que existe um override nativo nem instalar swizzle automaticamente."
            preferredStyle:UIAlertControllerStyleActionSheet];
        if (runtimeFallback) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Runtime experimental (swizzle)"
                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                    runtimeFallback();
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        WAGRABNativeConfigurePopover(alert, sourceView);
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(stableID, userContext, &mappingDiagnostic);
    if (!mapping) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"AB %@ · sem crosswalk nativo", stableID]
            message:mappingDiagnostic ?: @"WAMCEvaluation/UserSession não resolveu este ABProp para MobileConfig."
            preferredStyle:UIAlertControllerStyleActionSheet];
        if (runtimeFallback) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Runtime experimental (swizzle)"
                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                    runtimeFallback();
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        WAGRABNativeConfigurePopover(alert, sourceView);
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    id raw = nil;
    NSString *currentText = WAGRABPropsCurrentValue(entry, runtimeObjects ?: @[], &raw);
    NSString *nativeRow = WAGRABPropsNativeOverrideRow(stableID, userContext, NULL);
    NSString *nativeValue = WAGRABNativeValueFromRow(nativeRow);
    uint8_t nativeType = (uint8_t)[mapping[@"native_type"] unsignedIntegerValue];
    NSString *header = [NSString stringWithFormat:
        @"%@\n\nWA AB %@ → MC %@ / param %@\n%@",
        currentText ?: @"valor runtime indisponível",
        stableID,
        mapping[@"external_config_stable_id"] ?: @"?",
        mapping[@"parameter_index"] ?: @"?",
        nativeRow.length ? [@"Override nativo atual: " stringByAppendingString:nativeRow]
                         : @"Override nativo atual: nenhum"];

    if (nativeType == 1) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:entry.selectorName
            message:header preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"Aplicar YES · MobileConfig nativo"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSError *error = nil; NSString *diagnostic = nil;
                BOOL ok = WAGRABPropsNativeSetOverride(stableID, @YES, userContext, &error, &diagnostic);
                WAGRABNativeShowResult(presenter, @"ABProps native override", ok, error, diagnostic, completion);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Aplicar NO · MobileConfig nativo"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSError *error = nil; NSString *diagnostic = nil;
                BOOL ok = WAGRABPropsNativeSetOverride(stableID, @NO, userContext, &error, &diagnostic);
                WAGRABNativeShowResult(presenter, @"ABProps native override", ok, error, diagnostic, completion);
            }]];
        if (nativeRow.length) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Remover override nativo"
                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                    NSError *error = nil; NSString *diagnostic = nil;
                    BOOL ok = WAGRABPropsNativeClearOverride(stableID, userContext, &error, &diagnostic);
                    WAGRABNativeShowResult(presenter, @"ABProps native override", ok, error, diagnostic, completion);
                }]];
        }
        if (runtimeFallback) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Runtime experimental (swizzle)"
                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { runtimeFallback(); }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        WAGRABNativeConfigurePopover(alert, sourceView);
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (nativeType == 2 || nativeType == 4) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:entry.selectorName
            message:header preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            if (nativeValue.length) field.text = nativeValue;
            else if ([raw isKindOfClass:NSNumber.class]) field.text = [raw description];
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Aplicar nativo" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                NSString *text = alert.textFields.firstObject.text ?: @"";
                BOOL parsed = NO;
                NSNumber *value = nativeType == 2 ? WAGRABNativeParseInteger(text, &parsed)
                                                  : WAGRABNativeParseDouble(text, &parsed);
                if (!parsed || !value) {
                    WAGRABNativeShowResult(presenter, @"Valor inválido", NO,
                        [NSError errorWithDomain:@"WATweaks.ABPropsEditor" code:1
                            userInfo:@{NSLocalizedDescriptionKey : nativeType == 2
                                ? @"Informe um inteiro válido." : @"Informe um número decimal válido."}],
                        nil, nil);
                    return;
                }
                NSError *error = nil; NSString *diagnostic = nil;
                BOOL ok = WAGRABPropsNativeSetOverride(stableID, value, userContext, &error, &diagnostic);
                WAGRABNativeShowResult(presenter, @"ABProps native override", ok, error, diagnostic, completion);
            }]];
        if (nativeRow.length) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Remover override nativo"
                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                    NSError *error = nil; NSString *diagnostic = nil;
                    BOOL ok = WAGRABPropsNativeClearOverride(stableID, userContext, &error, &diagnostic);
                    WAGRABNativeShowResult(presenter, @"ABProps native override", ok, error, diagnostic, completion);
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (nativeType == 3) {
        WAGRABPropsNativeTextEditorVC *editor = [WAGRABPropsNativeTextEditorVC new];
        editor.stableID = stableID;
        editor.userContext = userContext;
        editor.completion = completion;
        [editor loadViewIfNeeded];
        NSString *initial = nativeValue;
        if (!initial.length) {
            if ([raw isKindOfClass:NSString.class]) initial = raw;
            else if ([raw isKindOfClass:NSDictionary.class] || [raw isKindOfClass:NSArray.class]) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:nil];
                initial = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : [raw description];
            } else if (raw) initial = [raw description];
        }
        editor.textView.text = initial ?: @"";
        if (presenter.navigationController) {
            [presenter.navigationController pushViewController:editor animated:YES];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
            [presenter presentViewController:nav animated:YES completion:nil];
        }
        return;
    }

    UIAlertController *unsupported = [UIAlertController alertControllerWithTitle:@"Tipo MobileConfig não suportado"
        message:[NSString stringWithFormat:@"AB %@ resolveu native_type=%u. Nenhum swizzle será aplicado automaticamente.", stableID, nativeType]
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (runtimeFallback) {
        [unsupported addAction:[UIAlertAction actionWithTitle:@"Runtime experimental (swizzle)"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { runtimeFallback(); }]];
    }
    [unsupported addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    WAGRABNativeConfigurePopover(unsupported, sourceView);
    [presenter presentViewController:unsupported animated:YES completion:nil];
}
