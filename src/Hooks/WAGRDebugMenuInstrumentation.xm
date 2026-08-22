// WAGRDebugMenuInstrumentation.xm
//
// Native Developer-menu instrumentation is intentionally capture-only.
// WATweaks must not add, replace, delete or relabel rows in WhatsApp's
// WADebugViewController. Its only job here is to remember the real account-
// scoped WAContext already owned by the native Developer controller.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <string.h>
#import "../Runtime/WAGRUserContextLinkage.h"
#import "../Runtime/WAGRLog.h"

@interface WADebugViewController : UIViewController
- (id)userContext;
@end

typedef void (*WAGRVoidIMP)(id, SEL);
typedef void (*WAGRVoidBoolIMP)(id, SEL, BOOL);

static WAGRVoidIMP orig_WADebugViewDidLoad = NULL;
static WAGRVoidBoolIMP orig_WADebugViewDidAppear = NULL;
static BOOL gWAGRDebugViewDidLoadHooked = NO;
static BOOL gWAGRDebugViewDidAppearHooked = NO;
static NSUInteger gWAGRDebugContextCaptureCount = 0;
static NSString *gWAGRDebugLastContextClass = nil;

static BOOL WAGRMethodIsVoidWithArguments(Method method,
                                           unsigned int argumentCount) {
    if (!method || method_getNumberOfArguments(method) != argumentCount) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *cursor = returnType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor == 'v';
}

static id WAGRDebugUserContext(WADebugViewController *controller) {
    if (!controller) return nil;
    SEL selector = NSSelectorFromString(@"userContext");
    Method method = class_getInstanceMethod([controller class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;

    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *cursor = returnType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    if (*cursor != '@') return nil;

    @try {
        return ((id (*)(id, SEL))objc_msgSend)(controller, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void WAGRCaptureDebugUserContext(WADebugViewController *controller,
                                        NSString *stage) {
    id context = WAGRDebugUserContext(controller);
    if (!context) {
        WAGRLogAppendF(@"[DebugMenu][Context] %@ userContext=nil", stage ?: @"?");
        return;
    }

    gWAGRDebugContextCaptureCount++;
    gWAGRDebugLastContextClass = [NSStringFromClass([context class]) copy] ?: @"unknown";
    WAGRRememberUserContext(context,
        [NSString stringWithFormat:@"WADebugViewController.%@.userContext", stage ?: @"runtime"]);
    WAGRLogAppendF(@"[DebugMenu][Context] captured %@ at %@ count=%lu",
                   gWAGRDebugLastContextClass,
                   stage ?: @"runtime",
                   (unsigned long)gWAGRDebugContextCaptureCount);
}

static void hook_WADebugViewDidLoad(id self, SEL _cmd) {
    if (orig_WADebugViewDidLoad) orig_WADebugViewDidLoad(self, _cmd);
    WAGRCaptureDebugUserContext((WADebugViewController *)self, @"viewDidLoad");
}

static void hook_WADebugViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_WADebugViewDidAppear) orig_WADebugViewDidAppear(self, _cmd, animated);
    WAGRCaptureDebugUserContext((WADebugViewController *)self, @"viewDidAppear");
}

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void) {
    Class cls = NSClassFromString(@"WADebugViewController");
    if (!cls) {
        WAGRLogAppend(@"[DebugMenu][Context] WADebugViewController not loaded");
        return;
    }

    if (!gWAGRDebugViewDidLoadHooked) {
        SEL selector = @selector(viewDidLoad);
        Method method = class_getInstanceMethod(cls, selector);
        if (WAGRMethodIsVoidWithArguments(method, 2)) {
            MSHookMessageEx(cls, selector, (IMP)hook_WADebugViewDidLoad,
                            (IMP *)&orig_WADebugViewDidLoad);
            gWAGRDebugViewDidLoadHooked = (orig_WADebugViewDidLoad != NULL);
        }
    }

    if (!gWAGRDebugViewDidAppearHooked) {
        SEL selector = @selector(viewDidAppear:);
        Method method = class_getInstanceMethod(cls, selector);
        if (WAGRMethodIsVoidWithArguments(method, 3)) {
            MSHookMessageEx(cls, selector, (IMP)hook_WADebugViewDidAppear,
                            (IMP *)&orig_WADebugViewDidAppear);
            gWAGRDebugViewDidAppearHooked = (orig_WADebugViewDidAppear != NULL);
        }
    }

    WAGRLogAppendF(@"[DebugMenu][Context] capture hooks load=%@ appear=%@; Developer UI untouched",
                   gWAGRDebugViewDidLoadHooked ? @"YES" : @"NO",
                   gWAGRDebugViewDidAppearHooked ? @"YES" : @"NO");
}

extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"Developer UI=untouched\ncontext capture load=%@ appear=%@\ncaptures=%lu\nlast context=%@",
        gWAGRDebugViewDidLoadHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidAppearHooked ? @"YES" : @"NO",
        (unsigned long)gWAGRDebugContextCaptureCount,
        gWAGRDebugLastContextClass ?: @"none"];
}

__attribute__((constructor))
static void WAGRDebugMenuInstrumentationCtor(void) {
    @autoreleasepool {
        WAGRDebugMenuInstrumentationEnsureInstalled();
    }
}
