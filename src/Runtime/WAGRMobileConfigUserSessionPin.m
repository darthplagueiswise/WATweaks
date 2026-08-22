#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

static const char *WAGRMCUSSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCUSReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCUSSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCUSWordArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRMCUSSkipQualifiers(raw);
    if (!*type || *type == '@' || *type == 'v' || *type == 'f' || *type == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static id WAGRMCUSCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMCUSReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static uint64_t WAGRMCUSStableId(id manager, uint64_t specifier) {
    if (!manager || !specifier) return 0;
    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRMCUSWordArgument(method, 2)) return 0;

    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRMCUSSkipQualifiers(raw);
    @try {
        if (*type == '@') {
            id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            if ([value respondsToSelector:@selector(unsignedLongLongValue)]) return [value unsignedLongLongValue];
            return strtoull([[value description] UTF8String] ?: "0", NULL, 10);
        }
        if (strchr("BcCsSiIlLqQ", *type)) {
            return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
        }
    } @catch (__unused NSException *exception) {}
    return 0;
}

static BOOL WAGRMCUSLooksLikeUserSessionManager(id manager) {
    if (!manager) return NO;
    NSString *name = NSStringFromClass([manager class]) ?: @"";
    if (![name containsString:@"FBMobileConfigUserSessionContextManager"]) return NO;
    Method stable = class_getInstanceMethod([manager class], NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    return stable && method_getNumberOfArguments(stable) == 3 && WAGRMCUSWordArgument(stable, 2);
}

static id WAGRMobileConfigPinUserSessionManager(void) {
    id context = WAGRCurrentUserContext();
    id manager = WAGRMCUSCallObjectNoArg(context, @"mobileConfig");
    if (!WAGRMCUSLooksLikeUserSessionManager(manager)) return nil;

    // The bridge captures managers transparently from getOverridesTablePath.
    // Calling the method here is read-only; doing it immediately before a scan
    // prevents the earlier sessionless bootstrap instance from winning the cache.
    id path = WAGRMCUSCallObjectNoArg(manager, @"getOverridesTablePath");

    // Known translated ABProp 1777 from the supplied SharedModules build.
    // This single probe makes the active-manager semantics visible in logs without
    // assuming that localConfigIndex=759 is the external mc_overrides config ID.
    const uint64_t sample1777 = 0x008102f700000227ULL;
    uint64_t resolved1777 = WAGRMCUSStableId(manager, sample1777);
    WAGRLogAppendF(@"[MobileConfig][UserSessionPin] context=%@ manager=%@ path=%@ sample1777_external=%llu",
                   context ? NSStringFromClass([context class]) : @"nil",
                   NSStringFromClass([manager class]) ?: @"?",
                   [path respondsToSelector:@selector(path)] ? [path path] : (path ?: @"nil"),
                   resolved1777);
    return manager;
}

static void (*orig_WAGRMCExportScanNow)(id, SEL) = NULL;
static void hook_WAGRMCExportScanNow(id self, SEL _cmd) {
    (void)WAGRMobileConfigPinUserSessionManager();
    if (orig_WAGRMCExportScanNow) orig_WAGRMCExportScanNow(self, _cmd);
}

static void (*orig_WAGRABSnapshotReload)(id, SEL) = NULL;
static void hook_WAGRABSnapshotReload(id self, SEL _cmd) {
    (void)WAGRMobileConfigPinUserSessionManager();
    if (orig_WAGRABSnapshotReload) orig_WAGRABSnapshotReload(self, _cmd);
}

static BOOL WAGRMCUSInstallMethodHook(NSString *className,
                                      NSString *selectorName,
                                      IMP replacement,
                                      IMP *original) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    IMP old = method_setImplementation(method, replacement);
    if (!old || old == replacement) return NO;
    if (original) *original = old;
    return YES;
}

static void WAGRMobileConfigInstallUserSessionPin(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        (void)WAGRMCUSInstallMethodHook(@"WAGRMobileConfigExportVC", @"scanNow",
            (IMP)hook_WAGRMCExportScanNow, (IMP *)&orig_WAGRMCExportScanNow);
        (void)WAGRMCUSInstallMethodHook(@"WAGRABPropsSnapshotVC", @"reloadLocalSnapshot",
            (IMP)hook_WAGRABSnapshotReload, (IMP *)&orig_WAGRABSnapshotReload);
        WAGRLogAppend(@"[MobileConfig][UserSessionPin] scan/snapshot preflight installed");
    });
}

__attribute__((constructor))
static void WAGRMobileConfigUserSessionPinCtor(void) {
    @autoreleasepool {
        WAGRMobileConfigInstallUserSessionPin();
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)WAGRMobileConfigPinUserSessionManager();
        });
    }
}
