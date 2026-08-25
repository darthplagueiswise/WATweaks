#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * wamo_abprops_list is an NSString getter whose native payload is compact JSON.
 * The full-screen editor intentionally pretty-prints JSON for readability, but
 * the previous Apply path persisted those editing newlines verbatim.  That is
 * why the runtime row collapsed to a single "{" after changing only false->true.
 *
 * Keep presentation and storage separate:
 *   - editor may be pretty/multiline;
 *   - Apply canonicalizes only this typed ABProps document back to compact JSON;
 *   - the outer Objective-C value remains NSString.
 *
 * IMPORTANT: do NOT parse+re-serialize merely to compact it. NSDictionary key
 * enumeration is not a wire-format contract and JSON serialization may also
 * normalize numeric/string lexical forms.  The native string's stable-id order
 * and lexical tokens should remain unchanged when the user only flips values.
 * We therefore remove JSON whitespace lexically, outside quoted strings only.
 * The original editor immediately parses and validates the resulting document.
 */

static void (*gWAGRCanonicalOriginalApply)(id, SEL) = NULL;

static id WAGRCanonicalKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRCanonicalBoolKVC(id object, NSString *key) {
    id value = WAGRCanonicalKVC(object, key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static BOOL WAGRCanonicalJSONWhitespace(unichar ch) {
    return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
}

static NSString *WAGRCanonicalCompactJSONLexically(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return text ?: @"";
    NSMutableString *output = [NSMutableString stringWithCapacity:text.length];
    BOOL inString = NO;
    BOOL escaped = NO;

    for (NSUInteger index = 0; index < text.length; index++) {
        unichar ch = [text characterAtIndex:index];
        if (inString) {
            [output appendFormat:@"%C", ch];
            if (escaped) {
                escaped = NO;
            } else if (ch == '\\') {
                escaped = YES;
            } else if (ch == '"') {
                inString = NO;
            }
            continue;
        }

        if (ch == '"') {
            inString = YES;
            escaped = NO;
            [output appendFormat:@"%C", ch];
            continue;
        }
        if (WAGRCanonicalJSONWhitespace(ch)) continue;
        [output appendFormat:@"%C", ch];
    }
    return output;
}

static void WAGRCanonicalApply(id self, SEL _cmd) {
    NSString *selectorName = WAGRCanonicalKVC(self, @"targetSelectorName");
    BOOL typedSchema = WAGRCanonicalBoolKVC(self, @"typedABPropsSchema");
    BOOL preserveString = WAGRCanonicalBoolKVC(self, @"preserveString");

    if (typedSchema && preserveString && [selectorName isEqualToString:@"wamo_abprops_list"]) {
        UITextView *textView = WAGRCanonicalKVC(self, @"textView");
        NSString *editingText = [textView isKindOfClass:UITextView.class] ? textView.text : nil;
        if (editingText.length) {
            // Preserve stable-id ordering, escaping and numeric lexical form.
            // The original applyPressed performs JSON + typed-schema validation
            // after this normalization and refuses malformed content.
            textView.text = WAGRCanonicalCompactJSONLexically(editingText);
        }
    }

    if (gWAGRCanonicalOriginalApply) gWAGRCanonicalOriginalApply(self, _cmd);
}

static void WAGRInstallCanonicalRuntimeJSON(void) {
    Class cls = NSClassFromString(@"WAGRFullValueEditorVC");
    SEL selector = NSSelectorFromString(@"applyPressed");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRCanonicalApply) return;
    gWAGRCanonicalOriginalApply = (void (*)(id, SEL))current;
    method_setImplementation(method, (IMP)WAGRCanonicalApply);
}

__attribute__((constructor))
static void WAGRRuntimeCanonicalJSONStringUICtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Fullscreen editor installs at 1.20 s.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.32 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WAGRInstallCanonicalRuntimeJSON();
            });
        });
    }
}
