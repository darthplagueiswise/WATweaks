#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRLog.h"

// Compatibility bridge for the current WhatsApp build. The real WAContext
// accessor is -xmppConnectionABPropsRequestManager. The dogfood2 exact-fetch
// resolver intentionally looks for the stable tweak-side name
// -abPropsRequestManager while traversing the userContext graph. Expose only
// that alias; the request itself remains owned by WAGRABPropsDogfood2Fixups.m.

static const char *WAGRDFSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRDFMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRDFSkipQualifiers(raw)[0] == '@';
}

static id WAGRDFExactABPropsRequestManager(id self, SEL _cmd) {
    (void)_cmd;
    SEL exact = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method method = class_getInstanceMethod([self class], exact);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRDFMethodReturnsObject(method)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(self, exact);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL gWAGRDFRequestAliasInstalled = NO;

static void WAGRDFInstallRequestManagerAlias(void) {
    if (gWAGRDFRequestAliasInstalled) return;
    Class cls = NSClassFromString(@"WAContext");
    if (!cls) return;

    SEL exact = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method exactMethod = class_getInstanceMethod(cls, exact);
    if (!exactMethod || method_getNumberOfArguments(exactMethod) != 2 ||
        !WAGRDFMethodReturnsObject(exactMethod)) return;

    SEL alias = NSSelectorFromString(@"abPropsRequestManager");
    Method existing = class_getInstanceMethod(cls, alias);
    if (existing || class_addMethod(cls, alias, (IMP)WAGRDFExactABPropsRequestManager, "@16@0:8")) {
        gWAGRDFRequestAliasInstalled = YES;
        WAGRLogAppend(@"[ABProps][FetchV2] WAContext exact request-manager bridge ready");
    }
}

__attribute__((constructor))
static void WAGRABPropsCurrentBuildBridgeCtor(void) {
    @autoreleasepool {
        WAGRDFInstallRequestManagerAlias();
        for (NSNumber *delay in @[@0.25, @0.75, @1.5, @3.0, @6.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRDFInstallRequestManagerAlias();
            });
        }
    }
}
