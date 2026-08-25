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
 * We deliberately do NOT use NSJSONWritingSortedKeys here.  The native document
 * is not sorted by the tweak and changing stable-id order is unnecessary churn.
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

static NSString *WAGRCanonicalCompactJSON(NSString *text, NSError **outError) {
    NSData *input = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!input.length) return nil;
    NSError *error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:input
                                               options:NSJSONReadingFragmentsAllowed
                                                 error:&error];
    if (!root || error) {
        if (outError) *outError = error;
        return nil;
    }
    if (![NSJSONSerialization isValidJSONObject:root]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"WATweaks.RuntimeJSON"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey:
                                            @"O valor não é um objeto/array JSON serializável."}];
        }
        return nil;
    }
    NSData *output = [NSJSONSerialization dataWithJSONObject:root options:0 error:&error];
    if (!output.length || error) {
        if (outError) *outError = error;
        return nil;
    }
    return [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
}

static void WAGRCanonicalShowError(UIViewController *controller, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"wamo_abprops_list"
        message:message ?: @"JSON inválido." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WAGRCanonicalApply(id self, SEL _cmd) {
    NSString *selectorName = WAGRCanonicalKVC(self, @"targetSelectorName");
    BOOL typedSchema = WAGRCanonicalBoolKVC(self, @"typedABPropsSchema");
    BOOL preserveString = WAGRCanonicalBoolKVC(self, @"preserveString");

    if (typedSchema && preserveString && [selectorName isEqualToString:@"wamo_abprops_list"]) {
        UITextView *textView = WAGRCanonicalKVC(self, @"textView");
        NSString *editingText = [textView isKindOfClass:UITextView.class] ? textView.text : nil;
        if (editingText.length) {
            NSError *error = nil;
            NSString *compact = WAGRCanonicalCompactJSON(editingText, &error);
            if (!compact.length) {
                WAGRCanonicalShowError(self, error.localizedDescription ?: @"JSON inválido.");
                return;
            }
            // The original editor performs the typed per-entry validation next.
            // We only normalize the representation passed to it.
            textView.text = compact;
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
