#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRABPropsRuntime.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

static id (*orig_WAGRMCABContextManager)(id, SEL) = NULL;

static const char *WAGRMCABSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCABReturnsObjectNoArg(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCABSkipQualifiers(raw)[0] == '@';
}

static id WAGRMCABCallObjectNoArg(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!WAGRMCABReturnsObjectNoArg(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRMCABIsUserSession(id object) {
    if (!object) return NO;
    Class expected = NSClassFromString(@"FBMobileConfigUserSessionContextManager") ?:
                     objc_getClass("FBMobileConfigUserSessionContextManager");
    if (expected) return [object isKindOfClass:expected];
    NSString *name = NSStringFromClass([object class]) ?: @"";
    if (![name containsString:@"UserSessionContextManager"]) return NO;
    Method stable = class_getInstanceMethod([object class],
        NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    Method path = class_getInstanceMethod([object class],
        NSSelectorFromString(@"getOverridesTablePath"));
    return stable && method_getNumberOfArguments(stable) == 3 &&
           path && WAGRMCABReturnsObjectNoArg(path);
}

static BOOL WAGRMCABLooksLikePropertiesObject(id object) {
    if (!object) return NO;
    Class base = NSClassFromString(@"WAProperties") ?: objc_getClass("WAProperties");
    if (base && [object isKindOfClass:base]) return YES;
    NSString *name = NSStringFromClass([object class]).lowercaseString ?: @"";
    return [name containsString:@"waabproperties"] ||
           [name containsString:@"foawaabproperties"] ||
           [name hasSuffix:@"waproperties"];
}

static id WAGRMCABResolveFromABPropsReceivers(id context) {
    NSArray *objects = WAGRABPropsResolveRuntimeObjects(context ?: WAGRCurrentUserContext());
    for (id object in objects) {
        if (!WAGRMCABLooksLikePropertiesObject(object)) continue;
        id manager = WAGRMCABCallObjectNoArg(object, @"mc");
        if (!WAGRMCABIsUserSession(manager)) continue;
        WAGRLogAppendF(@"[MobileConfig][ABPropsReceiverResolver] %@.mc -> %@",
            NSStringFromClass([object class]) ?: @"?",
            NSStringFromClass([manager class]) ?: @"?");
        return manager;
    }
    WAGRLogAppendF(@"[MobileConfig][ABPropsReceiverResolver] unresolved receivers=%lu",
                   (unsigned long)objects.count);
    return nil;
}

static id WAGRMCABContextManager(id self, SEL _cmd) {
    id original = nil;
    if (orig_WAGRMCABContextManager) {
        @try { original = orig_WAGRMCABContextManager(self, _cmd); }
        @catch (__unused NSException *exception) { original = nil; }
    }
    if (WAGRMCABIsUserSession(original)) return original;
    return WAGRMCABResolveFromABPropsReceivers(self);
}

static void WAGRMCABInstallOnClass(Class cls) {
    if (!cls) return;
    SEL selector = NSSelectorFromString(@"mobileConfigContextManager");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !WAGRMCABReturnsObjectNoArg(method)) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)WAGRMCABContextManager) return;
    // WAContext/WAContextMain share the same inherited method in most builds;
    // install only once for a given current IMP to avoid wrapping our wrapper.
    if (orig_WAGRMCABContextManager && current == (IMP)WAGRMCABContextManager) return;
    orig_WAGRMCABContextManager = (id (*)(id, SEL))current;
    method_setImplementation(method, (IMP)WAGRMCABContextManager);
}

static void WAGRMCABInstall(void) {
    for (NSString *name in @[@"WAContext", @"WAContextMain"]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        WAGRMCABInstallOnClass(cls);
    }
}

__attribute__((constructor))
static void WAGRMobileConfigABPropsReceiverResolverCtor(void) {
    @autoreleasepool {
        // Installation is narrow; receiver discovery happens only if the
        // context accessor is actually invoked by MobileConfig/Debug UI.
        for (NSNumber *delay in @[@1.15, @2.5, @5.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ WAGRMCABInstall(); });
        }
    }
}
