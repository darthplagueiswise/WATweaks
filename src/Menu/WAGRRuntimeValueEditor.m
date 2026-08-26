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
    if (WAGRRuntimeValueHasOverride(className, selectorName, meta)) {
        (void)WAGRRuntimeValueInstallHook(className, selectorName, meta, typeCode);
    }
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Aplicar"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        if (parseAndApply) parseAndApply(text);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void WAGRRuntimeShowParseError(UIViewController *presenter, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Valor inválido"
                                                                   message:message ?: @"Não foi possível converter o valor."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static id WAGRRuntimeParseJSON(NSString *text, NSString **error) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
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

static NSNumber *WAGRRuntimeParseDecimalNumber(NSString *text, NSString **error) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDecimalNumber *number = [NSDecimalNumber decimalNumberWithString:trimmed
                                                                locale:@{ NSLocaleDecimalSeparator: @"." }];
    if (!trimmed.length || [number isEqualToNumber:NSDecimalNumber.notANumber]) {
        if (error) *error = @"Número inválido.";
        return nil;
    }
    return number;
}

static NSString *WAGRRuntimeObjectInitialText(id value) {
    if (!value || value == NSNull.null) return @"";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value description];
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSData.class]) return [(NSData *)value base64EncodedStringWithOptions:0] ?: @"";
    if ([value isKindOfClass:NSDate.class]) return [NSString stringWithFormat:@"%.6f", [(NSDate *)value timeIntervalSince1970]];

    id jsonObject = value;
    if ([value isKindOfClass:NSSet.class]) jsonObject = [(NSSet *)value allObjects];
    if ([NSJSONSerialization isValidJSONObject:jsonObject]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObject
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return [value description] ?: @"";
}

static id WAGRRuntimeParseObjectText(NSString *text, id currentRaw, NSString **error) {
    if (error) *error = nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lower = trimmed.lowercaseString;

    if ([lower isEqualToString:@"nil"] || [lower isEqualToString:@"null"]) return NSNull.null;
    if ([lower hasPrefix:@"string:"]) return [trimmed substringFromIndex:7];
    if ([lower hasPrefix:@"number:"]) {
        return WAGRRuntimeParseDecimalNumber([trimmed substringFromIndex:7], error);
    }
    if ([lower hasPrefix:@"url:"]) {
        NSURL *url = [NSURL URLWithString:[trimmed substringFromIndex:4]];
        if (!url) { if (error) *error = @"URL inválida."; return nil; }
        return url;
    }
    if ([lower hasPrefix:@"data:"]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:[trimmed substringFromIndex:5]
                                                           options:0];
        if (!data) { if (error) *error = @"Base64 inválido."; return nil; }
        return data;
    }
    if ([lower hasPrefix:@"date:"]) {
        NSNumber *number = WAGRRuntimeParseDecimalNumber([trimmed substringFromIndex:5], error);
        return number ? [NSDate dateWithTimeIntervalSince1970:number.doubleValue] : nil;
    }
    if ([lower hasPrefix:@"json:"]) {
        return WAGRRuntimeParseJSON([trimmed substringFromIndex:5], error);
    }
    if ([lower hasPrefix:@"set:"]) {
        id object = WAGRRuntimeParseJSON([trimmed substringFromIndex:4], error);
        if (![object isKindOfClass:NSArray.class]) {
            if (error && !*error) *error = @"set: exige um array JSON.";
            return nil;
        }
        return [NSSet setWithArray:object];
    }

    if ([currentRaw isKindOfClass:NSNumber.class]) {
        return WAGRRuntimeParseDecimalNumber(trimmed, error);
    }
    if ([currentRaw isKindOfClass:NSURL.class]) {
        NSURL *url = [NSURL URLWithString:trimmed];
        if (!url) { if (error) *error = @"URL inválida."; return nil; }
        return url;
    }
    if ([currentRaw isKindOfClass:NSData.class]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:trimmed options:0];
        if (!data) { if (error) *error = @"Base64 inválido."; return nil; }
        return data;
    }
    if ([currentRaw isKindOfClass:NSDate.class]) {
        NSNumber *number = WAGRRuntimeParseDecimalNumber(trimmed, error);
        return number ? [NSDate dateWithTimeIntervalSince1970:number.doubleValue] : nil;
    }
    if ([currentRaw isKindOfClass:NSSet.class]) {
        id object = WAGRRuntimeParseJSON(trimmed, error);
        if (![object isKindOfClass:NSArray.class]) {
            if (error && !*error) *error = @"NSSet exige um array JSON.";
            return nil;
        }
        return [NSSet setWithArray:object];
    }
    if ([currentRaw isKindOfClass:NSArray.class] ||
        [currentRaw isKindOfClass:NSDictionary.class] ||
        [trimmed hasPrefix:@"["] || [trimmed hasPrefix:@"{"]) {
        return WAGRRuntimeParseJSON(trimmed, error);
    }
    return text ?: @"";
}

static NSString *WAGRRuntimeObjectHelp(id currentRaw) {
    NSString *currentClass = currentRaw ? NSStringFromClass([currentRaw class]) : @"nil";
    return [NSString stringWithFormat:
        @"Objeto atual: %@. Digite o valor mantendo o tipo atual, ou use prefixos explícitos: "
         "string:, number:, url:, data:<base64>, date:<timestamp>, json:<JSON>, set:<array JSON>. "
         "Para objetos customizados, a substituição por Foundation é avançada e pode ser rejeitada pelo consumidor.",
        currentClass];
}

static NSString *WAGRRuntimeCompactEditorValue(NSString *value) {
    if (!value.length) return @"?";
    NSString *flat = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (flat.length > 260) flat = [[flat substringToIndex:260] stringByAppendingString:@"…"];
    return flat;
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
    BOOL installed = overridden && WAGRRuntimeValueHookIsInstalled(className, selectorName, isClassMethod);
    id override = WAGRRuntimeValueOverride(className, selectorName, isClassMethod);
    NSString *typeName = WAGRRuntimeValueTypeName(typeCode) ?: typeCode;
    NSString *overrideDescription = overridden
        ? (override ? [override description] : @"nil")
        : nil;

    id originalRaw = nil;
    NSString *originalDescription = WAGRRuntimeValueReadOriginal(className,
                                                                  selectorName,
                                                                  isClassMethod,
                                                                  nil,
                                                                  &originalRaw);
    BOOL originalAvailable = ![originalDescription containsString:@"indisponível"];
    NSString *state = overridden ? (installed ? @"override instalado" : @"override pendente") : @"original";
    NSString *message = [NSString stringWithFormat:
        @"%@\n%@ method · %@ · %@\nOriginal: %@\nEfetivo: %@%@",
        className,
        isClassMethod ? @"class" : @"instance",
        typeName,
        state,
        originalAvailable ? WAGRRuntimeCompactEditorValue(originalDescription) : @"aguardando receiver vivo",
        WAGRRuntimeCompactEditorValue(currentDescription ?: @"?"),
        overridden ? [NSString stringWithFormat:@"\nOverride: %@", WAGRRuntimeCompactEditorValue(overrideDescription)] : @""];
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
            WAGRRuntimeEditorPrompt(presenter, selectorName, @"Inteiro decimal com sinal.", initial, UIKeyboardTypeNumbersAndPunctuation, ^(NSString *valueText) {
                NSScanner *scanner = [NSScanner scannerWithString:valueText];
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
            WAGRRuntimeEditorPrompt(presenter, selectorName, @"Inteiro decimal maior ou igual a zero.", initial, UIKeyboardTypeNumberPad, ^(NSString *valueText) {
                if (!valueText.length || [valueText hasPrefix:@"-"]) {
                    WAGRRuntimeShowParseError(presenter, @"Inteiro sem sinal inválido.");
                    return;
                }
                char *end = NULL;
                unsigned long long value = strtoull(valueText.UTF8String, &end, 10);
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
            WAGRRuntimeEditorPrompt(presenter, selectorName, @"Número decimal usando ponto.", initial, UIKeyboardTypeDecimalPad, ^(NSString *valueText) {
                NSScanner *scanner = [NSScanner scannerWithString:valueText];
                double value = 0.0;
                if (![scanner scanDouble:&value] || !scanner.isAtEnd) {
                    WAGRRuntimeShowParseError(presenter, @"Número decimal inválido.");
                    return;
                }
                WAGRRuntimeEditorApply(className, selectorName, isClassMethod, typeCode, @(value), completion);
            });
        }]];
    } else if (WAGRRuntimeValueTypeIsObject(typeCode)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Definir objeto Foundation…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id initialObject = overridden ? override : currentRawValue;
            NSString *initial = WAGRRuntimeObjectInitialText(initialObject);
            WAGRRuntimeEditorPrompt(presenter, selectorName, WAGRRuntimeObjectHelp(currentRawValue), initial, UIKeyboardTypeDefault, ^(NSString *valueText) {
                NSString *parseError = nil;
                id value = WAGRRuntimeParseObjectText(valueText, currentRawValue, &parseError);
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
    }

    if (overridden) {
        NSString *restoreTitle = originalAvailable ? @"Usar original" : @"Limpar override / usar original";
        [sheet addAction:[UIAlertAction actionWithTitle:restoreTitle style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            WAGRRuntimeValueClearOverride(className, selectorName, isClassMethod);
            if (completion) completion();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copiar nome + valores" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:
            @"%@ %@ %@ (%@)\nOriginal: %@\nEfetivo: %@%@",
            isClassMethod ? @"+" : @"-", className, selectorName, typeName,
            originalAvailable ? originalDescription : @"aguardando receiver vivo",
            currentDescription ?: @"?",
            overridden ? [NSString stringWithFormat:@"\nOverride: %@", overrideDescription ?: @"nil"] : @""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:sheet animated:YES completion:nil];
}