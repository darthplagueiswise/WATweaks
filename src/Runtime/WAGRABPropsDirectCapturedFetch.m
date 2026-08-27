#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "WAGRABPropsNativeStore.h"
#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"

// Direct bridge for the native ABProps refresh button.
//
// WAGRABPropsNativeStore intentionally accepts only the exact
// requestFreshABProps:withCompletion: ABI, but its historical resolver starts
// from userContext. The current runtime diagnostic proved a real
// XMPPConnectionABPropsRequestManager class/method exists while userContext was
// nil. Capture the concrete manager at its native initializer and let the UI use
// that exact object directly. The existing context-based resolver remains the
// fallback when this initializer was not observed.

static __weak id gWAGRDirectABManager = nil;
static id (*gWAGRDirectOriginalInit)(id, SEL, id, id) = NULL;
static void (*gWAGRDirectOriginalFetchNow)(id, SEL) = NULL;
static BOOL gWAGRDirectInitHookInstalled = NO;
static BOOL gWAGRDirectFetchHookInstalled = NO;

static const char *WAGRDirectSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRDirectReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRDirectSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRDirectArgObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRDirectSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRDirectCanFreshFetch(id object) {
    if (!object) return NO;
    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 4) return NO;

    char ret[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    if (WAGRDirectSkipQualifiers(ret)[0] != 'v') return NO;

    char delta[32] = {0};
    method_getArgumentType(method, 2, delta, sizeof(delta));
    char t = WAGRDirectSkipQualifiers(delta)[0];
    if (t != 'B' && t != 'c' && t != 'C') return NO;
    return WAGRDirectArgObject(method, 3);
}

static id WAGRDirectManagerInit(id self, SEL _cmd, id userContext, id xmppConnection) {
    id result = gWAGRDirectOriginalInit
        ? gWAGRDirectOriginalInit(self, _cmd, userContext, xmppConnection) : self;
    id manager = result ?: self;
    if (WAGRDirectCanFreshFetch(manager)) {
        gWAGRDirectABManager = manager;
        if (userContext) {
            WAGRRememberUserContext(userContext,
                @"direct XMPPConnectionABPropsRequestManager initializer capture");
        }
        WAGRLogAppendF(@"[ABProps][DirectFetch] captured manager=%@ context=%@",
                       NSStringFromClass([manager class]) ?: @"?",
                       userContext ? (NSStringFromClass([userContext class]) ?: @"?") : @"nil");
    }
    return result;
}

static void WAGRDirectInstallManagerCapture(void) {
    if (gWAGRDirectInitHookInstalled) return;
    Class cls = NSClassFromString(@"XMPPConnectionABPropsRequestManager") ?:
                objc_getClass("XMPPConnectionABPropsRequestManager");
    SEL selector = NSSelectorFromString(@"initWithUserContext:xmppConnection:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRDirectReturnsObject(method) ||
        !WAGRDirectArgObject(method, 2) || !WAGRDirectArgObject(method, 3)) return;

    IMP current = method_getImplementation(method);
    if (!current) return;
    if (current != (IMP)WAGRDirectManagerInit) {
        gWAGRDirectOriginalInit = (id (*)(id, SEL, id, id))current;
        method_setImplementation(method, (IMP)WAGRDirectManagerInit);
    }
    gWAGRDirectInitHookInstalled = YES;
}

static id WAGRDirectKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRDirectSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void WAGRDirectShowFetchError(id browser, NSString *message) {
    if (![browser isKindOfClass:UIViewController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ABProps Fetch"
        message:message ?: @"Fetch nativo não enviado."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [(UIViewController *)browser presentViewController:alert animated:YES completion:nil];
}

static void WAGRDirectFinishFetch(id browser, BOOL changed, NSString *note) {
    WAGRDirectSetKVC(browser, @"fetching", @NO);
    UIBarButtonItem *button = WAGRDirectKVC(browser, @"fetchButton");
    button.enabled = YES;
    NSString *finalNote = note ?: (changed
        ? @"Último Fetch: cache gabp.*p recebeu delta; runtime e cache foram relidos."
        : @"Último Fetch: request nativo enviado; nenhum delta local observado. Runtime e cache foram relidos.");
    WAGRDirectSetKVC(browser, @"lastFetchNote", finalNote);

    SEL scan = NSSelectorFromString(@"scanNow");
    if ([browser respondsToSelector:scan]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(browser, scan); }
        @catch (__unused NSException *exception) {}
    }
}

static void WAGRDirectFetchNow(id self, SEL _cmd) {
    id manager = gWAGRDirectABManager;
    if (!manager || !WAGRDirectCanFreshFetch(manager)) {
        if (gWAGRDirectOriginalFetchNow) gWAGRDirectOriginalFetchNow(self, _cmd);
        return;
    }

    if ([WAGRDirectKVC(self, @"fetching") boolValue]) return;
    WAGRDirectSetKVC(self, @"fetching", @YES);
    UIBarButtonItem *button = WAGRDirectKVC(self, @"fetchButton");
    button.enabled = NO;
    if ([self isKindOfClass:UIViewController.class]) {
        ((UIViewController *)self).title = @"Enviando Fetch ABProps…";
    }

    WAGRABPropsNativeSnapshot *beforeSnapshot = WAGRDirectKVC(self, @"nativeSnapshot");
    if (![beforeSnapshot isKindOfClass:WAGRABPropsNativeSnapshot.class]) {
        beforeSnapshot = WAGRABPropsReadNativeSnapshot(NULL);
    }
    NSString *beforeFingerprint = beforeSnapshot.fingerprint ?: @"";

    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    __weak id weakBrowser = self;
    void (^completion)(void) = ^{
        WAGRLogAppend(@"[ABProps][DirectFetch] native completion invoked");
    };

    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, selector, NO, completion);
        WAGRLogAppendF(@"[ABProps][DirectFetch] exact request sent via %@",
                       NSStringFromClass([manager class]) ?: @"XMPPConnectionABPropsRequestManager");
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"requestFreshABProps:NO threw %@",
                             exception.reason ?: @"exception"];
        dispatch_async(dispatch_get_main_queue(), ^{
            id browser = weakBrowser;
            if (!browser) return;
            WAGRDirectFinishFetch(browser, NO, message);
            WAGRDirectShowFetchError(browser, message);
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL changed = NO;
        for (NSUInteger attempt = 0; attempt < 8; attempt++) {
            [NSThread sleepForTimeInterval:0.5];
            WAGRABPropsNativeSnapshot *latest = WAGRABPropsReadNativeSnapshot(NULL);
            NSString *fingerprint = latest.fingerprint ?: @"";
            changed = fingerprint.length && ![fingerprint isEqualToString:beforeFingerprint];
            if (changed) break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            id browser = weakBrowser;
            if (!browser) return;
            WAGRDirectFinishFetch(browser, changed, nil);
        });
    });
}

static void WAGRDirectInstallBrowserFetch(void) {
    if (gWAGRDirectFetchHookInstalled) return;
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    SEL selector = NSSelectorFromString(@"fetchNow");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    IMP current = method ? method_getImplementation(method) : NULL;
    if (!method || !current) return;
    if (current != (IMP)WAGRDirectFetchNow) {
        gWAGRDirectOriginalFetchNow = (void (*)(id, SEL))current;
        method_setImplementation(method, (IMP)WAGRDirectFetchNow);
    }
    gWAGRDirectFetchHookInstalled = YES;
    WAGRLogAppend(@"[ABProps][DirectFetch] live browser now prefers captured exact request manager");
}

__attribute__((constructor))
static void WAGRABPropsDirectCapturedFetchCtor(void) {
    @autoreleasepool {
        WAGRDirectInstallManagerCapture();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRDirectInstallManagerCapture(); });
        // Install after the existing browser-context repair so this direct path
        // becomes the final Fetch handler when a captured manager is available.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WAGRDirectInstallManagerCapture();
            WAGRDirectInstallBrowserFetch();
        });
    }
}
