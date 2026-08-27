#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "WAGRABPropsRuntime.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

static NSObject *gWAGRMCABLock;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRMCABOriginalIMPs;

static void WAGRMCABEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRMCABLock = [NSObject new];
        gWAGRMCABOriginalIMPs = [NSMutableDictionary dictionary];
    });
}

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

static BOOL WAGRMCABClassOwnsSelector(Class cls, SEL selector, Method *outMethod) {
    if (outMethod) *outMethod = NULL;
    if (!cls || !selector) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    Method matched = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            matched = methods[index];
            break;
        }
    }
    if (outMethod) *outMethod = matched;
    if (methods) free(methods);
    return found;
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

static id (*WAGRMCABOriginalForObject(id object))(id, SEL) {
    if (!object) return NULL;
    WAGRMCABEnsureState();
    @synchronized (gWAGRMCABLock) {
        for (Class cls = [object class]; cls; cls = class_getSuperclass(cls)) {
            NSValue *boxed = gWAGRMCABOriginalIMPs[NSStringFromClass(cls) ?: @""];
            if (!boxed) continue;
            return (id (*)(id, SEL))[boxed pointerValue];
        }
    }
    return NULL;
}

static id WAGRMCABContextManager(id self, SEL _cmd) {
    id (*original)(id, SEL) = WAGRMCABOriginalForObject(self);
    id native = nil;
    if (original) {
        @try { native = original(self, _cmd); }
        @catch (__unused NSException *exception) { native = nil; }
    }
    if (WAGRMCABIsUserSession(native)) return native;
    return WAGRMCABResolveFromABPropsReceivers(self);
}

static void WAGRMCABInstallOnClass(Class cls) {
    if (!cls) return;
    WAGRMCABEnsureState();
    SEL selector = NSSelectorFromString(@"mobileConfigContextManager");
    Method method = NULL;
    if (!WAGRMCABClassOwnsSelector(cls, selector, &method) ||
        !WAGRMCABReturnsObjectNoArg(method)) return;

    IMP current = method_getImplementation(method);
    if (!current || current == (IMP)WAGRMCABContextManager) return;
    NSString *className = NSStringFromClass(cls) ?: @"";
    @synchronized (gWAGRMCABLock) {
        if (gWAGRMCABOriginalIMPs[className]) return;
        gWAGRMCABOriginalIMPs[className] = [NSValue valueWithPointer:(const void *)current];
    }
    method_setImplementation(method, (IMP)WAGRMCABContextManager);
    WAGRLogAppendF(@"[MobileConfig][ABPropsReceiverResolver] lazy accessor wrapped on %@",
                   className ?: @"?");
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
