#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

/*
 * Full-screen editor for long Foundation/JSON values.
 *
 * IMPORTANT CURRENT-BUILD FACT (WhatsApp(4), arm64):
 *   WAABProperties.wamo_abprops_list
 *     AB stable id : 19470
 *     ObjC ABI      : @16@0:8
 *     return kind   : object (live value is NSString)
 *
 * So wamo_abprops_list itself is NOT an int64 getter.  The JSON STRING returned
 * by that getter is a schema whose individual entries can declare e.g.
 *   {"type":"bool",  "default":false, ...}
 *   {"type":"string","default":"...", ...}
 *   {"type":"int64", "default":123, ...}
 *
 * By contrast, ordinary WAMO int64 getters really have q16@0:8; for example the
 * supplied executable has AB 25130/25131 as q16@0:8.  Replacing the outer
 * wamo_abprops_list ABI with q would therefore be wrong and crash-prone.
 *
 * This editor preserves the outer NSString ABI while validating the INTERNAL
 * JSON values against each entry's declared `type`.  That is the distinction
 * the previous generic JSON editor was missing.
 */

@interface WAGRFullValueEditorVC : UIViewController <UITextViewDelegate>
@property(nonatomic, copy) NSString *targetClassName;
@property(nonatomic, copy) NSString *targetSelectorName;
@property(nonatomic, copy) NSString *targetTypeCode;
@property(nonatomic, assign) BOOL targetMeta;
@property(nonatomic, strong) id sourceValue;
@property(nonatomic, assign) BOOL preserveString;
@property(nonatomic, assign) BOOL validateJSON;
@property(nonatomic, assign) BOOL typedABPropsSchema;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, copy) dispatch_block_t completion;
@end

static NSString *WAGRFullJSONString(id object, BOOL pretty) {
    if (!object || object == NSNull.null) return @"null";
    if (![NSJSONSerialization isValidJSONObject:object]) return nil;
    NSJSONWritingOptions options = pretty ? NSJSONWritingPrettyPrinted : 0;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:options error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static id WAGRFullParseJSON(NSString *text, NSString **errorText) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id object = data ? [NSJSONSerialization JSONObjectWithData:data
                                                       options:NSJSONReadingFragmentsAllowed
                                                         error:&error] : nil;
    if (!object || error) {
        if (errorText) *errorText = error.localizedDescription ?: @"JSON inválido.";
        return nil;
    }
    return object;
}

static BOOL WAGRFullLooksJSON(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["];
}

static BOOL WAGRFullIsJSONBool(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL WAGRFullIsJSONNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && !WAGRFullIsJSONBool(value);
}

static BOOL WAGRFullIsJSONInteger(id value) {
    if (!WAGRFullIsJSONNumber(value)) return NO;
    return !CFNumberIsFloatType((__bridge CFNumberRef)value);
}

static BOOL WAGRFullDecimalString(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return NO;
    return [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static BOOL WAGRFullValidateTypedValue(NSString *type,
                                       id value,
                                       NSString *stableID,
                                       NSString *field,
                                       NSString **errorText) {
    if (!value || value == NSNull.null) return YES; // nullable fields are preserved
    NSString *t = type.lowercaseString ?: @"";
    BOOL ok = YES;

    if ([t isEqualToString:@"bool"] || [t isEqualToString:@"boolean"]) {
        ok = WAGRFullIsJSONBool(value);
    } else if ([t isEqualToString:@"int64"] || [t isEqualToString:@"int"] ||
               [t isEqualToString:@"integer"] || [t isEqualToString:@"long"] ||
               [t isEqualToString:@"int32"]) {
        ok = WAGRFullIsJSONInteger(value);
    } else if ([t isEqualToString:@"uint64"] || [t isEqualToString:@"uint"] ||
               [t isEqualToString:@"uint32"]) {
        ok = WAGRFullIsJSONInteger(value) && [value longLongValue] >= 0;
    } else if ([t isEqualToString:@"double"] || [t isEqualToString:@"float"] ||
               [t isEqualToString:@"number"]) {
        ok = WAGRFullIsJSONNumber(value);
    } else if ([t isEqualToString:@"string"] || [t isEqualToString:@"str"]) {
        ok = [value isKindOfClass:NSString.class];
    } else if ([t isEqualToString:@"json"] || [t isEqualToString:@"object"] ||
               [t isEqualToString:@"dictionary"] || [t isEqualToString:@"array"]) {
        ok = [NSJSONSerialization isValidJSONObject:value] ||
             [value isKindOfClass:NSString.class] ||
             [value isKindOfClass:NSNumber.class];
    } else {
        // Unknown current/future WAMO type: preserve it.  We only reject types
        // whose semantics are known from the document itself.
        return YES;
    }

    if (!ok && errorText) {
        *errorText = [NSString stringWithFormat:
            @"AB %@ · %@ não corresponde ao tipo declarado '%@'.\n\nValor recebido: %@ (%@)",
            stableID ?: @"?", field ?: @"valor", type ?: @"?",
            [value description] ?: @"nil", NSStringFromClass([value class]) ?: @"?"];
    }
    return ok;
}

static BOOL WAGRFullValidateABPropsSchema(id root,
                                          NSUInteger *entryCount,
                                          NSUInteger *knownTypedCount,
                                          NSString **errorText) {
    if (entryCount) *entryCount = 0;
    if (knownTypedCount) *knownTypedCount = 0;
    if (![root isKindOfClass:NSDictionary.class]) {
        if (errorText) *errorText = @"wamo_abprops_list exige um objeto JSON no topo (dicionário stableID → descriptor).";
        return NO;
    }

    NSDictionary *dictionary = (NSDictionary *)root;
    __block NSString *failure = nil;
    __block NSUInteger total = 0;
    __block NSUInteger typed = 0;

    [dictionary enumerateKeysAndObjectsUsingBlock:^(id rawKey, id rawEntry, BOOL *stop) {
        NSString *stableID = [rawKey isKindOfClass:NSString.class] ? rawKey : [rawKey description];
        if (!WAGRFullDecimalString(stableID)) {
            failure = [NSString stringWithFormat:@"Chave '%@' não é um stable ID decimal válido.", stableID ?: @"?"];
            *stop = YES;
            return;
        }
        if (![rawEntry isKindOfClass:NSDictionary.class]) {
            failure = [NSString stringWithFormat:@"AB %@ deve apontar para um objeto descriptor.", stableID];
            *stop = YES;
            return;
        }

        NSDictionary *entry = (NSDictionary *)rawEntry;
        NSString *type = [entry[@"type"] isKindOfClass:NSString.class] ? entry[@"type"] : nil;
        if (!type.length) {
            failure = [NSString stringWithFormat:@"AB %@ não possui campo string 'type'.", stableID];
            *stop = YES;
            return;
        }

        total++;
        NSString *lower = type.lowercaseString;
        NSSet *known = [NSSet setWithArray:@[
            @"bool", @"boolean", @"int64", @"int", @"integer", @"long", @"int32",
            @"uint64", @"uint", @"uint32", @"double", @"float", @"number",
            @"string", @"str", @"json", @"object", @"dictionary", @"array"
        ]];
        if ([known containsObject:lower]) typed++;

        for (NSString *field in @[@"default", @"debugDefault"]) {
            id value = entry[field];
            if (!value) continue;
            NSString *fieldError = nil;
            if (!WAGRFullValidateTypedValue(type, value, stableID, field, &fieldError)) {
                failure = fieldError;
                *stop = YES;
                return;
            }
        }
    }];

    if (failure.length) {
        if (errorText) *errorText = failure;
        return NO;
    }
    if (entryCount) *entryCount = total;
    if (knownTypedCount) *knownTypedCount = typed;
    return YES;
}

static NSString *WAGRFullInitialText(id value, BOOL *preserveString, BOOL *json) {
    if (preserveString) *preserveString = NO;
    if (json) *json = NO;
    if (!value || value == NSNull.null) return @"";

    if ([value isKindOfClass:NSString.class]) {
        if (preserveString) *preserveString = YES;
        NSString *text = value;
        if (WAGRFullLooksJSON(text)) {
            NSString *error = nil;
            id parsed = WAGRFullParseJSON(text, &error);
            NSString *pretty = parsed ? WAGRFullJSONString(parsed, YES) : nil;
            if (pretty.length) {
                if (json) *json = YES;
                return pretty;
            }
        }
        return text;
    }
    if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
        if (json) *json = YES;
        return WAGRFullJSONString(value, YES) ?: [value description];
    }
    if ([value isKindOfClass:NSSet.class]) {
        if (json) *json = YES;
        return WAGRFullJSONString([(NSSet *)value allObjects], YES) ?: [value description];
    }
    if ([value isKindOfClass:NSData.class]) {
        return [(NSData *)value base64EncodedStringWithOptions:0] ?: @"";
    }
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSDate.class]) {
        return [NSString stringWithFormat:@"%.6f", [(NSDate *)value timeIntervalSince1970]];
    }
    return [value description] ?: @"";
}

@implementation WAGRFullValueEditorVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = self.targetSelectorName ?: @"Valor";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancelPressed)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone
        target:self action:@selector(applyPressed)];

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    status.textColor = UIColor.secondaryLabelColor;
    status.numberOfLines = self.typedABPropsSchema ? 4 : 2;
    if (self.typedABPropsSchema) {
        status.text = [NSString stringWithFormat:
            @"%@ · %@ method · %@\nOuter ABI: NSString/object (@), não int64\nJSON interno: stableID → {type, default, debugDefault}\nTipos internos são validados antes de aplicar.",
            self.targetClassName ?: @"Runtime",
            self.targetMeta ? @"class" : @"instance",
            WAGRRuntimeValueTypeName(self.targetTypeCode) ?: self.targetTypeCode ?: @"object"];
    } else {
        status.text = [NSString stringWithFormat:@"%@ · %@ method · %@\nObjeto original: %@%@",
            self.targetClassName ?: @"Runtime",
            self.targetMeta ? @"class" : @"instance",
            WAGRRuntimeValueTypeName(self.targetTypeCode) ?: self.targetTypeCode ?: @"object",
            self.sourceValue ? NSStringFromClass([self.sourceValue class]) : @"nil",
            self.preserveString && self.validateJSON ? @" · JSON armazenado como NSString" : @""];
    }
    [self.view addSubview:status];
    self.statusLabel = status;

    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.alwaysBounceVertical = YES;
    text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    text.autocorrectionType = UITextAutocorrectionTypeNo;
    text.autocapitalizationType = UITextAutocapitalizationTypeNone;
    text.smartQuotesType = UITextSmartQuotesTypeNo;
    text.smartDashesType = UITextSmartDashesTypeNo;
    text.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    text.textContainerInset = UIEdgeInsetsMake(12, 10, 18, 10);
    text.delegate = self;
    text.text = WAGRFullInitialText(self.sourceValue, NULL, NULL);
    [self.view addSubview:text];
    self.textView = text;

    UIButton *format = [UIButton buttonWithType:UIButtonTypeSystem];
    format.translatesAutoresizingMaskIntoConstraints = NO;
    [format setTitle:@"Formatar" forState:UIControlStateNormal];
    [format addTarget:self action:@selector(formatPressed) forControlEvents:UIControlEventTouchUpInside];

    UIButton *validate = [UIButton buttonWithType:UIButtonTypeSystem];
    validate.translatesAutoresizingMaskIntoConstraints = NO;
    [validate setTitle:self.typedABPropsSchema ? @"Validar tipos" : @"Validar JSON"
              forState:UIControlStateNormal];
    [validate addTarget:self action:@selector(validatePressed) forControlEvents:UIControlEventTouchUpInside];

    UIButton *original = [UIButton buttonWithType:UIButtonTypeSystem];
    original.translatesAutoresizingMaskIntoConstraints = NO;
    [original setTitle:@"Original" forState:UIControlStateNormal];
    [original addTarget:self action:@selector(originalPressed) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[format, validate, original]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;
    [self.view addSubview:buttons];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [status.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],

        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [buttons.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:8],
        [buttons.heightAnchor constraintEqualToConstant:36],

        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [text.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:6],
        [text.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (void)cancelPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)formatPressed {
    NSString *error = nil;
    id object = WAGRFullParseJSON(self.textView.text ?: @"", &error);
    NSString *pretty = object ? WAGRFullJSONString(object, YES) : nil;
    if (pretty.length) {
        self.textView.text = pretty;
        self.validateJSON = YES;
        return;
    }
    [self showError:error ?: @"O texto não é JSON válido."];
}

- (void)validatePressed {
    NSString *error = nil;
    id object = WAGRFullParseJSON(self.textView.text ?: @"", &error);
    if (!object) {
        [self showError:error ?: @"JSON inválido."];
        return;
    }
    if (self.typedABPropsSchema) {
        NSUInteger entries = 0, typed = 0;
        if (!WAGRFullValidateABPropsSchema(object, &entries, &typed, &error)) {
            [self showError:error ?: @"Schema WAMO inválido."];
            return;
        }
        UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"Schema válido"
            message:[NSString stringWithFormat:@"%lu entries · %lu com tipo conhecido/validado.\nO getter externo continua NSString (@16@0:8).",
                     (unsigned long)entries, (unsigned long)typed]
            preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ok animated:YES completion:nil];
        return;
    }
    UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"JSON válido"
        message:@"A estrutura JSON é válida." preferredStyle:UIAlertControllerStyleAlert];
    [ok addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ok animated:YES completion:nil];
}

- (void)originalPressed {
    WAGRRuntimeValueClearOverride(self.targetClassName,
                                  self.targetSelectorName,
                                  self.targetMeta);
    if (self.completion) self.completion();
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)applyPressed {
    NSString *text = self.textView.text ?: @"";
    id value = nil;

    if (self.preserveString) {
        if (self.validateJSON || WAGRFullLooksJSON(text)) {
            NSString *error = nil;
            id parsed = WAGRFullParseJSON(text, &error);
            if (!parsed) {
                [self showError:error ?: @"JSON inválido."];
                return;
            }
            if (self.typedABPropsSchema) {
                NSUInteger entries = 0, typed = 0;
                if (!WAGRFullValidateABPropsSchema(parsed, &entries, &typed, &error)) {
                    [self showError:error ?: @"Schema WAMO inválido."];
                    return;
                }
            }
        }
        // Outer ABI is object.  For wamo_abprops_list the live object is NSString;
        // keep the JSON document as NSString.  int64/bool/string apply INSIDE the
        // JSON according to each descriptor's `type`, not to the getter ABI.
        value = text;
    } else if ([self.sourceValue isKindOfClass:NSDictionary.class] ||
               [self.sourceValue isKindOfClass:NSArray.class]) {
        NSString *error = nil;
        value = WAGRFullParseJSON(text, &error);
        if (!value) { [self showError:error]; return; }
    } else if ([self.sourceValue isKindOfClass:NSSet.class]) {
        NSString *error = nil;
        id parsed = WAGRFullParseJSON(text, &error);
        if (![parsed isKindOfClass:NSArray.class]) {
            [self showError:error ?: @"NSSet exige um array JSON."];
            return;
        }
        value = [NSSet setWithArray:parsed];
    } else if ([self.sourceValue isKindOfClass:NSData.class]) {
        value = [[NSData alloc] initWithBase64EncodedString:text options:0];
        if (!value) { [self showError:@"Base64 inválido."]; return; }
    } else if ([self.sourceValue isKindOfClass:NSURL.class]) {
        value = [NSURL URLWithString:text];
        if (!value) { [self showError:@"URL inválida."]; return; }
    } else {
        value = text;
    }

    WAGRRuntimeValueSetOverride(self.targetClassName,
                                self.targetSelectorName,
                                self.targetMeta,
                                self.targetTypeCode,
                                value);
    BOOL installed = WAGRRuntimeValueInstallHook(self.targetClassName,
                                                  self.targetSelectorName,
                                                  self.targetMeta,
                                                  self.targetTypeCode);
    if (self.completion) self.completion();
    if (!installed) {
        [self showError:@"O valor foi salvo como override, mas o hook imediato não pôde ser instalado. Ele foi mantido para uma nova tentativa em Aplicar/reinício."];
        return;
    }
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Editor"
        message:message ?: @"Valor inválido." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static void WAGRPushFullEditor(UIViewController *presenter,
                               NSString *className,
                               NSString *selectorName,
                               BOOL meta,
                               NSString *typeCode,
                               id raw,
                               dispatch_block_t completion) {
    if (!presenter.navigationController) return;
    id effective = WAGRRuntimeValueHasOverride(className, selectorName, meta)
        ? WAGRRuntimeValueOverride(className, selectorName, meta) : raw;

    BOOL preserveString = NO;
    BOOL json = NO;
    (void)WAGRFullInitialText(effective, &preserveString, &json);

    WAGRFullValueEditorVC *editor = [WAGRFullValueEditorVC new];
    editor.targetClassName = className;
    editor.targetSelectorName = selectorName;
    editor.targetTypeCode = typeCode;
    editor.targetMeta = meta;
    editor.sourceValue = effective;
    editor.preserveString = preserveString;
    editor.typedABPropsSchema = [selectorName isEqualToString:@"wamo_abprops_list"];
    editor.validateJSON = json || [selectorName.lowercaseString containsString:@"json"] ||
                          [selectorName.lowercaseString containsString:@"abprops_list"];
    editor.completion = completion;
    [presenter.navigationController pushViewController:editor animated:YES];
}

static void (*gWAGROriginalABPresentEditor)(id, SEL, WAGRABPropEntry *, UIView *) = NULL;
static void (*gWAGROriginalSurfacePresentEditor)(id, SEL, WAGREntry *, UIView *) = NULL;
static UITableViewCell *(*gWAGROriginalABCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static id WAGRObjectSafeKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRFullABPresentEditor(id self, SEL _cmd,
                                    WAGRABPropEntry *entry,
                                    UIView *sourceView) {
    if (!entry || !WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        if (gWAGROriginalABPresentEditor) gWAGROriginalABPresentEditor(self, _cmd, entry, sourceView);
        return;
    }
    NSArray *objects = WAGRObjectSafeKVC(self, @"runtimeObjects") ?: @[];
    id raw = nil;
    (void)WAGRABPropsCurrentValue(entry, objects, &raw);
    __weak id weakSelf = self;
    WAGRPushFullEditor(self, entry.className, entry.selectorName,
                       entry.classMethod, entry.typeCode, raw, ^{
        id target = weakSelf;
        SEL filter = NSSelectorFromString(@"applyCurrentFilter");
        if (target && [target respondsToSelector:filter]) {
            ((void (*)(id, SEL))objc_msgSend)(target, filter);
        }
    });
}

static void WAGRFullSurfacePresentEditor(id self, SEL _cmd,
                                         WAGREntry *entry,
                                         UIView *sourceView) {
    if (!entry || !WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        if (gWAGROriginalSurfacePresentEditor) gWAGROriginalSurfacePresentEditor(self, _cmd, entry, sourceView);
        return;
    }
    id raw = nil;
    SEL current = NSSelectorFromString(@"currentForEntry:raw:");
    if ([self respondsToSelector:current]) {
        (void)((id (*)(id, SEL, id, id *))objc_msgSend)(self, current, entry, &raw);
    }
    __weak id weakSelf = self;
    WAGRPushFullEditor(self, entry.className, entry.selectorName,
                       entry.isClassMethod, entry.typeCode, raw, ^{
        id target = weakSelf;
        SEL filter = NSSelectorFromString(@"applyCurrentFilter");
        if (target && [target respondsToSelector:filter]) {
            ((void (*)(id, SEL))objc_msgSend)(target, filter);
        }
    });
}

static UITableViewCell *WAGRFullABCell(id self, SEL _cmd,
                                       UITableView *table,
                                       NSIndexPath *path) {
    UITableViewCell *cell = gWAGROriginalABCell
        ? gWAGROriginalABCell(self, _cmd, table, path) : nil;
    UITextField *field = [cell.accessoryView isKindOfClass:UITextField.class]
        ? (UITextField *)cell.accessoryView : nil;
    NSString *value = field.text ?: @"";
    // Long/structured strings belong in the full-screen editor. Short scalar
    // strings keep the convenient inline field.
    if (field && (value.length > 96 || WAGRFullLooksJSON(value))) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRFullInstallOnClass(Class cls,
                                   SEL selector,
                                   IMP replacement,
                                   IMP *oldStorage) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == replacement) return;
    if (oldStorage && !*oldStorage) *oldStorage = current;
    method_setImplementation(method, replacement);
}

static void WAGRInstallFullRuntimeEditors(void) {
    Class ab = NSClassFromString(@"WAGRABPropsBrowserVC");
    WAGRFullInstallOnClass(ab,
        NSSelectorFromString(@"presentEditorForEntry:fromView:"),
        (IMP)WAGRFullABPresentEditor,
        (IMP *)&gWAGROriginalABPresentEditor);

    // Capture the final ABI-aware cell renderer, then decorate only long object
    // rows. This makes wamo_abprops_list visibly navigable instead of squeezing
    // thousands of JSON characters into a small inline text field.
    WAGRFullInstallOnClass(ab,
        @selector(tableView:cellForRowAtIndexPath:),
        (IMP)WAGRFullABCell,
        (IMP *)&gWAGROriginalABCell);

    Class surface = NSClassFromString(@"WAGRSurfaceBrowserVC");
    WAGRFullInstallOnClass(surface,
        NSSelectorFromString(@"presentEditorForEntry:fromView:"),
        (IMP)WAGRFullSurfacePresentEditor,
        (IMP *)&gWAGROriginalSurfacePresentEditor);
}

__attribute__((constructor))
static void WAGRRuntimeObjectFullscreenEditorCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // InlineTypedUI retries at 0.35 s and FastTypedUI at 0.85 s.
            // Install after both so this is the final long-object presentation.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WAGRInstallFullRuntimeEditors();
            });
        });
    }
}
