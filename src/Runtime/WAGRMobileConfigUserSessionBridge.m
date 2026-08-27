#import "WAGRMobileConfigUserSessionBridge.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <string.h>

static NSObject *gWAGRMCUSLock;
static id gWAGRMCUSManager;
static NSString *gWAGRMCUSSource;
static NSMutableArray<NSDictionary<NSString *, id> *> *gWAGRMCEevents;
static BOOL gWAGRMCUSWAPropertiesHooked;
static BOOL gWAGRMCUSWAABPropertiesHooked;
static void (*orig_WAGRMCUSWAPropertiesSetMC)(id, SEL, id) = NULL;
static void (*orig_WAGRMCUSWAABPropertiesSetMC)(id, SEL, id) = NULL;

static void WAGRMCUSEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRMCUSLock = [NSObject new];
        gWAGRMCEevents = [NSMutableArray array];
    });
}

static const char *WAGRMCUSSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCUSMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCUSSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCUSMethodReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCUSSkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRMCUSArgumentIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRMCUSSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCUSArgumentFitsWord(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[128] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRMCUSSkipQualifiers(raw);
    if (!*type) return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static NSString *WAGRMCUSMethodEncoding(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return @"";
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"";
}

static BOOL WAGRMCUSClassDescendsFrom(Class cls, Class base) {
    if (!cls || !base) return NO;
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == base) return YES;
    }
    return NO;
}

static BOOL WAGRMCUSObjectIsUserSessionManager(id object) {
    if (!object) return NO;
    Class expected = NSClassFromString(@"FBMobileConfigUserSessionContextManager") ?:
                     objc_getClass("FBMobileConfigUserSessionContextManager");
    if (expected && [object isKindOfClass:expected]) return YES;

    NSString *name = NSStringFromClass([object class]) ?: @"";
    if (![name containsString:@"UserSessionContextManager"]) return NO;

    Method stable = class_getInstanceMethod([object class],
        NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    Method path = class_getInstanceMethod([object class],
        NSSelectorFromString(@"getOverridesTablePath"));
    return stable && method_getNumberOfArguments(stable) == 3 &&
           WAGRMCUSArgumentFitsWord(stable, 2) &&
           path && method_getNumberOfArguments(path) == 2 &&
           WAGRMCUSMethodReturnsObject(path);
}

static void WAGRMCUSRecordEvent(NSString *kind, NSString *source, id object) {
    WAGRMCUSEnsureState();
    NSDictionary *event = @{
        @"time" : @([[NSDate date] timeIntervalSince1970]),
        @"kind" : kind ?: @"event",
        @"source" : source ?: @"unknown",
        @"class" : object ? (NSStringFromClass([object class]) ?: @"?") : @"nil",
    };
    @synchronized (gWAGRMCUSLock) {
        [gWAGRMCEevents addObject:event];
        if (gWAGRMCEevents.count > 48) {
            [gWAGRMCEevents removeObjectsInRange:NSMakeRange(0, gWAGRMCEevents.count - 48)];
        }
    }
}

static void WAGRMCUSRememberManager(id manager, NSString *source) {
    if (!WAGRMCUSObjectIsUserSessionManager(manager)) {
        if (manager) WAGRMCUSRecordEvent(@"rejected_non_user_session", source, manager);
        return;
    }
    WAGRMCUSEnsureState();
    @synchronized (gWAGRMCUSLock) {
        gWAGRMCUSManager = manager;
        gWAGRMCUSSource = [source copy] ?: @"unknown";
    }
    WAGRMCUSRecordEvent(@"captured_user_session", source, manager);
    WAGRLogAppendF(@"[MobileConfig][UserSessionBridge] captured %@ from %@",
                   NSStringFromClass([manager class]) ?: @"?", source ?: @"unknown");
}

static id WAGRMCUSCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRMCUSMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRMCUSClassOwnsInstanceSelector(Class cls, SEL selector) {
    if (!cls || !selector) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) { owns = YES; break; }
    }
    if (methods) free(methods);
    return owns;
}

static BOOL WAGRMCUSSetMobileConfigABIIsValid(Class cls) {
    SEL selector = NSSelectorFromString(@"setMobileConfig:");
    Method method = class_getInstanceMethod(cls, selector);
    return method && method_getNumberOfArguments(method) == 3 &&
           WAGRMCUSMethodReturnsVoid(method) && WAGRMCUSArgumentIsObject(method, 2);
}

static void hook_WAGRMCUSWAPropertiesSetMC(id self, SEL _cmd, id manager) {
    WAGRMCUSRememberManager(manager, @"WAProperties.setMobileConfig:");
    if (orig_WAGRMCUSWAPropertiesSetMC) orig_WAGRMCUSWAPropertiesSetMC(self, _cmd, manager);
}

static void hook_WAGRMCUSWAABPropertiesSetMC(id self, SEL _cmd, id manager) {
    WAGRMCUSRememberManager(manager, @"WAABProperties.setMobileConfig:");
    if (orig_WAGRMCUSWAABPropertiesSetMC) orig_WAGRMCUSWAABPropertiesSetMC(self, _cmd, manager);
}

static void WAGRMCUSEnsureSetMobileConfigHooks(void) {
    WAGRMCUSEnsureState();
    @synchronized (gWAGRMCUSLock) {
        SEL selector = NSSelectorFromString(@"setMobileConfig:");
        Class waProperties = NSClassFromString(@"WAProperties") ?: objc_getClass("WAProperties");
        if (!gWAGRMCUSWAPropertiesHooked && waProperties &&
            WAGRMCUSClassOwnsInstanceSelector(waProperties, selector) &&
            WAGRMCUSSetMobileConfigABIIsValid(waProperties)) {
            MSHookMessageEx(waProperties, selector, (IMP)hook_WAGRMCUSWAPropertiesSetMC,
                            (IMP *)&orig_WAGRMCUSWAPropertiesSetMC);
            gWAGRMCUSWAPropertiesHooked = (orig_WAGRMCUSWAPropertiesSetMC != NULL);
            WAGRMCUSRecordEvent(@"hook_install", @"WAProperties.setMobileConfig:", waProperties);
        }

        Class waAB = NSClassFromString(@"WAABProperties") ?: objc_getClass("WAABProperties");
        if (!gWAGRMCUSWAABPropertiesHooked && waAB &&
            WAGRMCUSClassOwnsInstanceSelector(waAB, selector) &&
            WAGRMCUSSetMobileConfigABIIsValid(waAB)) {
            MSHookMessageEx(waAB, selector, (IMP)hook_WAGRMCUSWAABPropertiesSetMC,
                            (IMP *)&orig_WAGRMCUSWAABPropertiesSetMC);
            gWAGRMCUSWAABPropertiesHooked = (orig_WAGRMCUSWAABPropertiesSetMC != NULL);
            WAGRMCUSRecordEvent(@"hook_install", @"WAABProperties.setMobileConfig:", waAB);
        }
    }
}

static BOOL WAGRMCUSObjectIsWAPropertiesFamily(id object) {
    if (!object) return NO;
    Class base = NSClassFromString(@"WAProperties") ?: objc_getClass("WAProperties");
    if (base && [object isKindOfClass:base]) return YES;
    NSString *name = NSStringFromClass([object class]) ?: @"";
    return [name containsString:@"WAABProperties"] ||
           [name hasSuffix:@"WAProperties"] ||
           [name containsString:@"FOAWAABProperties"];
}

static id WAGRMCUSManagerFromPropertiesObject(id object, NSString *source) {
    if (!WAGRMCUSObjectIsWAPropertiesFamily(object)) return nil;
    id manager = WAGRMCUSCallObjectNoArg(object, @"mc");
    if (!manager) return nil;
    WAGRMCUSRecordEvent(@"wa_properties_mc", source, manager);
    if (!WAGRMCUSObjectIsUserSessionManager(manager)) return nil;
    WAGRMCUSRememberManager(manager, source);
    return manager;
}

static id WAGRMCUSResolveByNarrowObjectWalk(id root) {
    if (!root) return nil;

    NSArray<NSString *> *accessors = @[
        @"abProperties", @"waABProperties", @"serverProperties", @"waProperties",
        @"properties", @"propertiesStore", @"experimentProperties",
        @"accountProvider", @"userContext", @"context", @"appContext",
        @"dependencyProvider", @"networkingDependencyProvider", @"networking"
    ];

    NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{
        @"object" : root, @"depth" : @0, @"route" : @"userContext"
    }];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    NSUInteger cursor = 0;

    while (cursor < queue.count && visited.count < 64) {
        NSDictionary *node = queue[cursor++];
        id object = node[@"object"];
        NSUInteger depth = [node[@"depth"] unsignedIntegerValue];
        NSString *route = node[@"route"] ?: @"object";
        if (!object) continue;

        NSValue *identity = [NSValue valueWithNonretainedObject:object];
        if ([visited containsObject:identity]) continue;
        [visited addObject:identity];

        id manager = WAGRMCUSManagerFromPropertiesObject(object,
            [route stringByAppendingString:@".mc"]);
        if (manager) return manager;
        if (depth >= 3) continue;

        for (NSString *selectorName in accessors) {
            id child = WAGRMCUSCallObjectNoArg(object, selectorName);
            if (!child || child == object) continue;
            [queue addObject:@{
                @"object" : child,
                @"depth" : @(depth + 1),
                @"route" : [NSString stringWithFormat:@"%@.%@", route, selectorName]
            }];
            if (queue.count >= 96) break;
        }
    }

    WAGRMCUSRecordEvent(@"narrow_walk_unresolved", @"WAProperties.mc", nil);
    return nil;
}

id WAGRMobileConfigLiveCapturedUserSessionManager(void) {
    WAGRMCUSEnsureState();
    @synchronized (gWAGRMCUSLock) {
        return WAGRMCUSObjectIsUserSessionManager(gWAGRMCUSManager) ? gWAGRMCUSManager : nil;
    }
}

id WAGRMobileConfigLiveUserSessionManager(id userContext) {
    WAGRMCUSEnsureSetMobileConfigHooks();
    id captured = WAGRMobileConfigLiveCapturedUserSessionManager();
    if (captured) return captured;
    return WAGRMCUSResolveByNarrowObjectWalk(userContext);
}

static id WAGRMCUSContextAccessor(id self, SEL _cmd) {
    (void)_cmd;
    return WAGRMobileConfigLiveUserSessionManager(self);
}

static BOOL WAGRMCUSInstallContextAccessorOnClass(Class cls) {
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(@"mobileConfigContextManager");
    Method existing = class_getInstanceMethod(cls, selector);
    if (existing) return WAGRMCUSMethodReturnsObject(existing) &&
                         method_getNumberOfArguments(existing) == 2;
    return class_addMethod(cls, selector, (IMP)WAGRMCUSContextAccessor, "@16@0:8");
}

static void WAGRMCUSInstallContextAccessors(void) {
    BOOL installed = NO;
    for (NSString *name in @[@"WAContext", @"WAContextMain"]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (WAGRMCUSInstallContextAccessorOnClass(cls)) installed = YES;
    }
    if (installed) {
        WAGRLogAppend(@"[MobileConfig][UserSessionBridge] context forwarding accessor ready");
    }
}

static NSDictionary *WAGRMCUSClassMethodSummary(Class cls) {
    if (!cls) return @{};
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *selectorName in @[
        @"mc", @"setMobileConfig:", @"getStableIdFromParamSpecifier:",
        @"getOverridesTablePath", @"hasValidManager", @"hasValidConfig",
        @"getBool:", @"getInt64:", @"getString:", @"getDouble:",
        @"overrides", @"setOverrides:", @"forceInvalidate",
        @"invalidateCachedLatestContext", @"forceRefreshOfConfig:"
    ]) {
        NSString *encoding = WAGRMCUSMethodEncoding(cls, selectorName);
        if (encoding.length) summary[selectorName] = encoding;
    }
    return summary;
}

NSDictionary<NSString *, id> *WAGRMobileConfigLiveCaptureDiagnosticDocument(id userContext) {
    id resolved = WAGRMobileConfigLiveUserSessionManager(userContext);
    WAGRMCUSEnsureState();

    NSArray *events = nil;
    NSString *source = nil;
    @synchronized (gWAGRMCUSLock) {
        events = [gWAGRMCEevents copy] ?: @[];
        source = [gWAGRMCUSSource copy] ?: @"unresolved";
    }

    Class userSessionClass = NSClassFromString(@"FBMobileConfigUserSessionContextManager") ?:
                             objc_getClass("FBMobileConfigUserSessionContextManager");
    Class waProperties = NSClassFromString(@"WAProperties") ?: objc_getClass("WAProperties");
    Class waAB = NSClassFromString(@"WAABProperties") ?: objc_getClass("WAABProperties");

    return @{
        @"context_class" : userContext ? (NSStringFromClass([userContext class]) ?: @"?") : @"nil",
        @"resolved" : @(resolved != nil),
        @"resolved_class" : resolved ? (NSStringFromClass([resolved class]) ?: @"?") : @"nil",
        @"capture_source" : source,
        @"user_session_class_present" : @(userSessionClass != Nil),
        @"wa_properties_class_present" : @(waProperties != Nil),
        @"waab_properties_class_present" : @(waAB != Nil),
        @"wa_properties_set_mc_hooked" : @(gWAGRMCUSWAPropertiesHooked),
        @"waab_properties_set_mc_hooked" : @(gWAGRMCUSWAABPropertiesHooked),
        @"wa_properties_methods" : WAGRMCUSClassMethodSummary(waProperties),
        @"waab_properties_methods" : WAGRMCUSClassMethodSummary(waAB),
        @"resolved_manager_methods" : resolved ? WAGRMCUSClassMethodSummary([resolved class]) : @{},
        @"events" : events,
    };
}

NSString *WAGRMobileConfigLiveCaptureDiagnosticText(id userContext) {
    NSDictionary *doc = WAGRMobileConfigLiveCaptureDiagnosticDocument(userContext);
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                       : [doc description];
}

__attribute__((constructor))
static void WAGRMobileConfigUserSessionBridgeCtor(void) {
    @autoreleasepool {
        // Only publish a lazy forwarding accessor during cold start. Actual
        // WAProperties walking and setMobileConfig: hooks are deferred until a
        // MobileConfig/Debug action asks for the UserSession manager.
        WAGRMCUSInstallContextAccessors();
        for (NSNumber *delay in @[@0.25, @0.75, @1.5, @3.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ WAGRMCUSInstallContextAccessors(); });
        }
    }
}
