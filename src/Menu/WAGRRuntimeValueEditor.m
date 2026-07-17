#import "WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#include <stdlib.h>

static void WAGRRuntimeEditorApply(NSString *className,
                                   NSString *selectorName,
                                   BOOL meta,
                                   NSString *typeCode,
                                   id value,
                                   dispatch_block_t completion) {
    WAGRRuntimeValueSetOverride(className, selectorName, meta, typeCode, value);
    (void)WAGRRuntimeValueInstallHook(className, selectorName, meta, typeCode);
    if (completion) completion();
}

static void WAGRRuntimeEditorPrompt(UIViewController *presenter,
                                    NSString *title,
                                    NSString *message,
                                    NSString *initial,
                                    UIKeyboardType keyboard,
                                    void (^parseAndApply)(NSString *text)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = initial ?: @"";
        field.keyboardType = keyboard;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Aplicar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        if (parseAndApply) parseAndApply(text);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static id WAGRRuntimeParseObjectText(NSString *text, id currentRaw, NSString **error) {
    if (error) *error = nil;
    if ([currentRaw isKindOfClass:NSNumber.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
        double value = 0.0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd) {
            if (error) *error = @"Número inválido.";
            return nil;
        }
        return @(value);
    }

    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([currentRaw isKindOfClass:NSArray.class] ||
        [currentRaw isKindOfClass:NSDictionary.class] ||
        [trimmed hasPrefix:@"["] || [trimmed hasPrefix:@"{"]) {
        NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        NSError *jsonError = nil;
        id object = data ? [NSJSONSerialization JSONObjectWithData:data
                                                           options:NSJSONReadingFragmentsAllowed
                                                             error:&jsonError] : nil;
        if (!object || jsonError) {
            if (error) *error = jsonError.localizedDescription ?: @"JSON inválido.";
            return nil;
        }
        return object;
    }
    return text ?: @"";
}

static void WAGRRuntimeShowParseError(UIViewController *presenter, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Valor inválido"
                                                                   message:message ?: @"Não foi possível converter o valor."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

void WAGRPresentRuntimeValueEditor(UIViewController *presenter,
                                   UIView *sourceView,
                                   NSString *className,
                                   NSString *selectorName,
                                   BOOL isClassMethod,
                                   NSString *typeCode,
                                   NSString *currentDescription,
                                   id currentRawValue,
                                   dispatch_block_t completion) {
    if (!presenter || !className.length || !selectorName.length || !typeCode.length) return;

    BOOL overridden = WAGRRuntimeValueHasOverride(className, selectorName, isClassMethod);
    id override = WAGRRuntimeValueOverride(className, selectorName, isClassMethod);
    NSString *typeName = WAGRRuntimeValueTypeName(typeCode) ?: typeCode;
    NSString *message = [NSString stringWithFormat:@"%@\n%@ method · %@\nAtual: %@%@",
                         className,
                         isClassMethod ? @"class" : @"instance",
                         typeName,
                         currentDescription ?: @"?",
                         overridden ? [NSString stringWithFormat:@"\nOverride: %@", override ?: @"nil"] : @""];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:selectorName
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = sourceView ?: presenter.view;
    sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : presenter.view.bounds;

    if (WAGRRuntimeValueTypeIsBoolean(typeCode)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force YES" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, @YES, completion);
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force NO" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, @NO, completion);
        }]];
    } else if (WAGRRuntimeValueTypeIsSignedInteger(typeCode)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Definir inteiro…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *initial = overridden ? [override description] : [currentRawValue description];
            WAGRRuntimeEditorPrompt(presenter, selectorName, @"Inteiro decimal com sinal.", initial, UIKeyboardTypeNumbersAndPunctuation, ^(NSString *text) {
                NSScanner *scanner = [NSScanner scannerWithString:text];
                long long value = 0;
                if (![scanner scanLongLong:&value] || !scanner.isAtEnd) {
                    WAGRRuntimeShowParseError(presenter, @"Inteiro decimal inválido.");
                    return;
                }
                WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, @(value), completion);
            });
        }]];
    } else if (WAGRRuntimeValueTypeIsUnsignedInteger(typeCode)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Definir inteiro sem sinal…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *initial = overridden ? [override description] : [currentRawValue description];
            WAGRRuntimeEditorPrompt(presenter, selectorName, @"Inteiro decimal maior ou igual a zero.", initial, UIKeyboardTypeNumberPad, ^(NSString *text) {
                if (!text.length || [text hasPrefix:@"-"]) {
                    WAGRRuntimeShowParseError(presenter, @"Inteiro sem sinal inválido.");
                    return;
                }
                char *end = NULL;
                unsigned long long value = strtoull(text.UTF8String, &end, 10);
                if (!end || *end != '\0') {
                    WAGRRuntimeShowParseError(presenter, @"Inteiro decimal inválido.");
                    return;
                }
                WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, @(value), completion);
            });
        }]];
    } else if (WAGRRuntimeValueTypeIsFloatingPoint(typeCode)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Definir decimal…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *initial = overridden ? [override description] : [currentRawValue description];
            WAGRRuntimeEditorPrompt(presenter, selectorName, @"Número decimal.", initial, UIKeyboardTypeDecimalPad, ^(NSString *text) {
                NSScanner *scanner = [NSScanner scannerWithString:text];
                double value = 0.0;
                if (![scanner scanDouble:&value] || !scanner.isAtEnd) {
                    WAGRRuntimeShowParseError(presenter, @"Número decimal inválido.");
                    return;
                }
                WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, @(value), completion);
            });
        }]];
    } else if (WAGRRuntimeValueTypeIsObject(typeCode)) {
        BOOL editableObject = !currentRawValue ||
            [currentRawValue isKindOfClass:NSString.class] ||
            [currentRawValue isKindOfClass:NSNumber.class] ||
            [currentRawValue isKindOfClass:NSArray.class] ||
            [currentRawValue isKindOfClass:NSDictionary.class] ||
            currentRawValue == NSNull.null;
        if (editableObject) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Definir objeto/JSON…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSString *initial = overridden ? [override description] : [currentRawValue description];
                if ([currentRawValue isKindOfClass:NSArray.class] || [currentRawValue isKindOfClass:NSDictionary.class]) {
                    NSData *data = [NSJSONSerialization dataWithJSONObject:currentRawValue options:0 error:nil];
                    if (data) initial = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                }
                WAGRRuntimeEditorPrompt(presenter, selectorName,
                    @"String, número ou JSON. O tipo do objeto atual é preservado quando possível.",
                    initial, UIKeyboardTypeDefault, ^(NSString *text) {
                        NSString *parseError = nil;
                        id value = WAGRRuntimeParseObjectText(text, currentRawValue, &parseError);
                        if (!value) {
                            WAGRRuntimeShowParseError(presenter, parseError);
                            return;
                        }
                        WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, value, completion);
                    });
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Force nil" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, NSNull.null, completion);
            }]];
        } else {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Objeto customizado: copiar para hook tipado" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@ %@ %@ = %@",
                    isClassMethod ? @"+" : @"-", className, selectorName, currentDescription ?: @"?"];
            }]];
        }
    }

    if (overridden) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Usar original" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            WAGRRuntimeValueClearOverride(className, selectorName, isClassMethod);
            if (completion) completion();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar nome + valor" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@ %@ %@ (%@) = %@",
            isClassMethod ? @"+" : @"-", className, selectorName, typeName, currentDescription ?: @"?"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:sheet animated:YES completion:nil];
}
