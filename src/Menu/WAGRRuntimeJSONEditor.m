#import "WAGRRuntimeJSONEditor.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

static id WAGRJSONParseString(NSString *text, NSError **error) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingFragmentsAllowed
                                             error:error];
}

BOOL WAGRRuntimeValueLooksLikeJSON(id value) {
    if (!value || value == NSNull.null) return NO;
    if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) return YES;
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed hasPrefix:@"{"] && ![trimmed hasPrefix:@"["]) return NO;
    NSError *error = nil;
    return WAGRJSONParseString(trimmed, &error) != nil && error == nil;
}

static NSString *WAGRJSONTextForValue(id value) {
    if (!value || value == NSNull.null) return @"null";
    id object = value;
    if ([value isKindOfClass:NSString.class]) {
        NSError *error = nil;
        id parsed = WAGRJSONParseString(value, &error);
        if (!parsed || error) return value;
        object = parsed;
    }
    if ([NSJSONSerialization isValidJSONObject:object]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return [value description] ?: @"";
}

@interface WAGRRuntimeJSONEditorVC : UIViewController
@property(nonatomic, copy) NSString *targetTitle;
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *typeCode;
@property(nonatomic, assign) BOOL classMethod;
@property(nonatomic, strong) id originalValue;
@property(nonatomic, copy) dispatch_block_t completion;
@property(nonatomic, strong) UITextView *textView;
@end

@implementation WAGRRuntimeJSONEditorVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = self.targetTitle.length ? self.targetTitle : @"JSON";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Salvar" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(save)],
        [[UIBarButtonItem alloc] initWithTitle:@"Formatar" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(formatJSON)]
    ];

    UILabel *hint = [UILabel new];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    hint.textColor = UIColor.secondaryLabelColor;
    NSString *kind = self.originalValue ? NSStringFromClass([self.originalValue class]) : @"nil";
    hint.text = [NSString stringWithFormat:@"%@ · %@ %@%@\nO tipo Foundation original é preservado ao salvar.",
                 kind, self.className ?: @"?", self.classMethod ? @"+" : @"-",
                 self.selectorName ?: @"?"];

    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.backgroundColor = UIColor.secondarySystemBackgroundColor;
    text.textColor = UIColor.labelColor;
    text.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    text.autocorrectionType = UITextAutocorrectionTypeNo;
    text.autocapitalizationType = UITextAutocapitalizationTypeNone;
    text.smartQuotesType = UITextSmartQuotesTypeNo;
    text.smartDashesType = UITextSmartDashesTypeNo;
    text.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    text.text = WAGRJSONTextForValue(self.originalValue);
    text.layer.cornerRadius = 14.0;
    text.layer.masksToBounds = YES;
    text.textContainerInset = UIEdgeInsetsMake(14, 12, 14, 12);
    self.textView = text;

    [self.view addSubview:hint];
    [self.view addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [hint.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [text.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:10],
        [text.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [text.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [text.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8],
    ]];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"JSON inválido"
        message:message ?: @"Não foi possível interpretar o JSON."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)validatedObject:(NSError **)outError {
    NSString *text = self.textView.text ?: @"";
    NSError *error = nil;
    id parsed = WAGRJSONParseString(text, &error);
    if (!parsed || error) {
        if (outError) *outError = error;
        return nil;
    }
    if ([self.originalValue isKindOfClass:NSDictionary.class] && ![parsed isKindOfClass:NSDictionary.class]) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks.JSON" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"O valor original é NSDictionary; o JSON raiz precisa continuar sendo um objeto {…}."}];
        return nil;
    }
    if ([self.originalValue isKindOfClass:NSArray.class] && ![parsed isKindOfClass:NSArray.class]) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks.JSON" code:3
            userInfo:@{NSLocalizedDescriptionKey:@"O valor original é NSArray; o JSON raiz precisa continuar sendo um array […]."}];
        return nil;
    }
    return parsed;
}

- (void)formatJSON {
    NSError *error = nil;
    id parsed = [self validatedObject:&error];
    if (!parsed) { [self showError:error.localizedDescription]; return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:parsed options:NSJSONWritingPrettyPrinted error:&error];
    if (!data || error) { [self showError:error.localizedDescription]; return; }
    self.textView.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: self.textView.text;
}

- (void)save {
    NSError *error = nil;
    id parsed = [self validatedObject:&error];
    if (!parsed) { [self showError:error.localizedDescription]; return; }

    id value = parsed;
    if ([self.originalValue isKindOfClass:NSString.class]) {
        // Preserve NSString. Compact serialization also keeps huge WAMO schema
        // payloads materially smaller than pretty-printing them into the override.
        NSData *data = [NSJSONSerialization dataWithJSONObject:parsed options:0 error:&error];
        if (!data || error) { [self showError:error.localizedDescription]; return; }
        value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }

    WAGRRuntimeValueSetOverride(self.className, self.selectorName,
                                self.classMethod, self.typeCode, value);
    (void)WAGRRuntimeValueInstallHook(self.className, self.selectorName,
                                      self.classMethod, self.typeCode);
    dispatch_block_t completion = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{ if (completion) completion(); }];
}

@end

void WAGRPresentRuntimeJSONEditor(UIViewController *presenter,
                                  NSString *title,
                                  NSString *className,
                                  NSString *selectorName,
                                  BOOL isClassMethod,
                                  NSString *typeCode,
                                  id currentValue,
                                  dispatch_block_t completion) {
    if (!presenter || !className.length || !selectorName.length || !typeCode.length ||
        !WAGRRuntimeValueLooksLikeJSON(currentValue)) return;
    WAGRRuntimeJSONEditorVC *editor = [WAGRRuntimeJSONEditorVC new];
    editor.targetTitle = title ?: selectorName;
    editor.className = className;
    editor.selectorName = selectorName;
    editor.classMethod = isClassMethod;
    editor.typeCode = typeCode;
    editor.originalValue = currentValue;
    editor.completion = completion;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}
