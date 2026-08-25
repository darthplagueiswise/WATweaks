#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

/*
 * Full-screen editor for long Foundation/JSON values.
 *
 * In particular, current WhatsApp exposes WAABProperties.wamo_abprops_list as
 * an Objective-C object getter whose live value is an NSString containing a
 * large JSON document.  UIAlertController.message + one text field is not an
 * acceptable editor for that value: it truncates the document and makes it
 * effectively impossible to inspect or modify safely.
 *
 * This layer keeps the original Objective-C return kind.  A JSON-looking
 * NSString is formatted for editing, but Apply still stores an NSString rather
 * than silently changing the getter into NSDictionary/NSArray.
 */

@interface WAGRFullValueEditorVC : UIViewController <UITextViewDelegate>
@property(nonatomic, copy) NSString *targetClassName;
@property(nonatomic, copy) NSString *targetSelectorName;
@property(nonatomic, copy) NSString *targetTypeCode;
@property(nonatomic, assign) BOOL targetMeta;
@property(nonatomic, strong) id sourceValue;
@property(nonatomic, assign) BOOL preserveString;
@property(nonatomic, assign) BOOL validateJSON;
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
    status.numberOfLines = 2;
    status.text = [NSString stringWithFormat:@"%@ · %@ method · %@\nObjeto original: %@%@",
        self.targetClassName ?: @"Runtime",
        self.targetMeta ? @"class" : @"instance",
        WAGRRuntimeValueTypeName(self.targetTypeCode) ?: self.targetTypeCode ?: @"object",
        self.sourceValue ? NSStringFromClass([self.sourceValue class]) : @"nil",
        self.preserveString && self.validateJSON ? @" · JSON armazenado como NSString" : @""];
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
    [format setTitle:@"Formatar JSON" forState:UIControlStateNormal];
    [format addTarget:self action:@selector(formatPressed) forControlEvents:UIControlEventTouchUpInside];

    UIButton *original = [UIButton buttonWithType:UIButtonTypeSystem];
    original.translatesAutoresizingMaskIntoConstraints = NO;
    [original setTitle:@"Usar original" forState:UIControlStateNormal];
    [original addTarget:self action:@selector(originalPressed) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[format, original]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 12;
    [self.view addSubview:buttons];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [status.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],

        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
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
            if (!WAGRFullParseJSON(text, &error)) {
                [self showError:error ?: @"JSON inválido."];
                return;
            }
        }
        // Critical: wamo_abprops_list is __NSCFString in the supplied build.
        // Keep it a string even when its payload happens to be JSON.
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
    // Long/structured strings belong in the full-screen editor.  Short scalar
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
    // rows.  This makes wamo_abprops_list visibly navigable instead of squeezing
    // thousands of JSON characters into a 138-pt text field.
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
