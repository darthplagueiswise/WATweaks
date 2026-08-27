#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "WAGRDebugDiagnosticsVC.h"
#import "../Runtime/WAGRMobileConfigNativeEngine.h"

extern id WAGRCurrentUserContext(void);

static NSDictionary *(*orig_WAGRDebugBuildDocument)(id, SEL, BOOL) = NULL;

static NSDictionary *WAGRDebugBuildDocumentWithNativeEngine(id self, SEL _cmd, BOOL deep) {
    NSDictionary *base = orig_WAGRDebugBuildDocument
        ? orig_WAGRDebugBuildDocument(self, _cmd, deep) : @{};
    NSMutableDictionary *document = [base mutableCopy] ?: [NSMutableDictionary dictionary];
    document[@"mobileconfig_native_engine"] =
        WAGRMobileConfigNativeEngineDiagnosticDocument(WAGRCurrentUserContext()) ?: @{};
    return document;
}

static void WAGRDebugInstallNativeEngineEnrichment(void) {
    Class cls = NSClassFromString(@"WAGRDebugDiagnosticsVC");
    SEL selector = NSSelectorFromString(@"buildDiagnosticDocumentDeep:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRDebugBuildDocumentWithNativeEngine) return;
    orig_WAGRDebugBuildDocument = (NSDictionary *(*)(id, SEL, BOOL))current;
    method_setImplementation(method, (IMP)WAGRDebugBuildDocumentWithNativeEngine);
}

__attribute__((constructor))
static void WAGRDebugNativeEngineEnrichmentCtor(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRDebugInstallNativeEngineEnrichment(); });
    }
}
