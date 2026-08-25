#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/*
 * Generic JSON-string policy for BOTH ABProps and the generic runtime browser.
 *
 * The outer Objective-C ABI decides the return object. A getter returning @ may
 * legitimately return NSString whose contents are JSON. The editor is allowed
 * to pretty-print that JSON for humans, but Apply must not accidentally turn a
 * native one-line payload into a multiline string just because the editor did.
 *
 * This policy deliberately does NOT special-case wamo_abprops_list. Any
 * NSString payload that parses as JSON gets the same lexical preservation rule.
 * A stable-ID -> {type, default, debugDefault} document is detected from its
 * structure, not from the selector name.
 */

static void (*gWAGRJSONOriginalViewDidLoad)(id, SEL) = NULL;
static void (*gWAGRJSONOriginalApply)(id, SEL) = NULL;

static id WAGRJSONKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRJSONSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static BOOL WAGRJSONBoolKVC(id object, NSString *key) {
    id value = WAGRJSONKVC(object, key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static id WAGRJSONParseString(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingFragmentsAllowed
                                             error:nil];
}

static BOOL WAGRJSONDecimalKey(id rawKey) {
    NSString *key = [rawKey isKindOfClass:NSString.class] ? rawKey : [rawKey description];
    if (!key.length) return NO;
    return [key rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static BOOL WAGRJSONLooksTypedABPropsDocument(id object) {
    if (![object isKindOfClass:NSDictionary.class] || ![(NSDictionary *)object count]) return NO;
    __block BOOL valid = YES;
    __block NSUInteger seen = 0;
    [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (!WAGRJSONDecimalKey(key) || ![value isKindOfClass:NSDictionary.class]) {
            valid = NO; *stop = YES; return;
        }
        id type = ((NSDictionary *)value)[@"type"];
        if (![type isKindOfClass:NSString.class] || ![(NSString *)type length]) {
            valid = NO; *stop = YES; return;
        }
        seen++;
    }];
    return valid && seen > 0;
}

static BOOL WAGRJSONWhitespace(unichar ch) {
    return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
}

/* Remove only insignificant JSON whitespace outside quoted strings.  This does
 * not parse/re-serialize, so key order, escaping and numeric lexical forms stay
 * exactly as the user/native document supplied them. */
static NSString *WAGRJSONCompactLexically(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return text ?: @"";
    NSMutableString *output = [NSMutableString stringWithCapacity:text.length];
    BOOL inString = NO;
    BOOL escaped = NO;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar ch = [text characterAtIndex:index];
        if (inString) {
            [output appendFormat:@"%C", ch];
            if (escaped) escaped = NO;
            else if (ch == '\\') escaped = YES;
            else if (ch == '"') inString = NO;
            continue;
        }
        if (ch == '"') {
            inString = YES;
            escaped = NO;
            [output appendFormat:@"%C", ch];
            continue;
        }
        if (WAGRJSONWhitespace(ch)) continue;
        [output appendFormat:@"%C", ch];
    }
    return output;
}

static void WAGRJSONViewDidLoad(id self, SEL _cmd) {
    id source = WAGRJSONKVC(self, @"sourceValue");
    id parsed = nil;
    if ([source isKindOfClass:NSString.class]) parsed = WAGRJSONParseString(source);
    else if ([source isKindOfClass:NSDictionary.class] || [source isKindOfClass:NSArray.class]) parsed = source;

    if (parsed) {
        WAGRJSONSetKVC(self, @"validateJSON", @YES);
        if (WAGRJSONLooksTypedABPropsDocument(parsed)) {
            WAGRJSONSetKVC(self, @"typedABPropsSchema", @YES);
        }
    }

    if (gWAGRJSONOriginalViewDidLoad) gWAGRJSONOriginalViewDidLoad(self, _cmd);

    if (WAGRJSONBoolKVC(self, @"typedABPropsSchema")) {
        UILabel *status = WAGRJSONKVC(self, @"statusLabel");
        NSString *className = WAGRJSONKVC(self, @"targetClassName") ?: @"Runtime";
        NSString *selector = WAGRJSONKVC(self, @"targetSelectorName") ?: @"getter";
        if ([status isKindOfClass:UILabel.class]) {
            status.numberOfLines = 4;
            status.text = [NSString stringWithFormat:
                @"%@ · %@\nOuter ABI: object (@); o tipo real do objeto é preservado.\nJSON tipado detectado por estrutura: stableID → {type, default, debugDefault}.\nA validação é estrutural, não depende do nome do selector.",
                className, selector];
        }
    }
}

static void WAGRJSONApply(id self, SEL _cmd) {
    BOOL preserveString = WAGRJSONBoolKVC(self, @"preserveString");
    UITextView *textView = WAGRJSONKVC(self, @"textView");
    NSString *editingText = [textView isKindOfClass:UITextView.class] ? textView.text : nil;

    if (preserveString && editingText.length) {
        id parsed = WAGRJSONParseString(editingText);
        if (parsed) {
            // Same policy for every JSON-valued NSString getter in ABProps and
            // Runtime. Editing can be pretty; the returned NSString stays a
            // compact JSON wire value instead of persisting editor newlines.
            textView.text = WAGRJSONCompactLexically(editingText);
            WAGRJSONSetKVC(self, @"validateJSON", @YES);
            if (WAGRJSONLooksTypedABPropsDocument(parsed)) {
                WAGRJSONSetKVC(self, @"typedABPropsSchema", @YES);
            }
        }
    }

    if (gWAGRJSONOriginalApply) gWAGRJSONOriginalApply(self, _cmd);
}

static void WAGRJSONReplace(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == replacement) return;
    if (original && !*original) *original = current;
    method_setImplementation(method, replacement);
}

static void WAGRInstallGenericRuntimeJSONPolicy(void) {
    Class cls = NSClassFromString(@"WAGRFullValueEditorVC");
    if (!cls) return;
    WAGRJSONReplace(cls, @selector(viewDidLoad), (IMP)WAGRJSONViewDidLoad,
                    (IMP *)&gWAGRJSONOriginalViewDidLoad);
    WAGRJSONReplace(cls, NSSelectorFromString(@"applyPressed"), (IMP)WAGRJSONApply,
                    (IMP *)&gWAGRJSONOriginalApply);
}

__attribute__((constructor))
static void WAGRRuntimeCanonicalJSONStringUICtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Fullscreen editor installs at 1.20 s.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.32 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WAGRInstallGenericRuntimeJSONPolicy();
            });
        });
    }
}
