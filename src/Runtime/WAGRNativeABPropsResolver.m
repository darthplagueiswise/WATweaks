#import "WAGRNativeABPropsResolver.h"
#import "WAGRABPropsRuntime.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>

static NSString *gWAGRNativeABPropsLastDiagnostic = @"not attempted";
static NSObject *gWAGRNativeABPropsDiagnosticLock = nil;

static void WAGRNativeABPropsSetDiagnostic(NSString *text) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRNativeABPropsDiagnosticLock = [NSObject new];
    });
    @synchronized (gWAGRNativeABPropsDiagnosticLock) {
        gWAGRNativeABPropsLastDiagnostic = [text copy] ?: @"unknown";
    }
    WAGRLogAppendF(@"[ABProps][NativeResolver] %@", text ?: @"unknown");
}

NSString *WAGRNativeABPropsResolverDiagnosticText(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRNativeABPropsDiagnosticLock = [NSObject new];
    });
    @synchronized (gWAGRNativeABPropsDiagnosticLock) {
        return [gWAGRNativeABPropsLastDiagnostic copy] ?: @"unknown";
    }
}

static const char *WAGRSkipObjCTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMethodReturnsObject(Method method, unsigned int argumentCount) {
    if (!method || method_getNumberOfArguments(method) != argumentCount) return NO;
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return WAGRSkipObjCTypeQualifiers(returnType)[0] == '@';
}

static id WAGRCallZeroArgumentObject(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!WAGRMethodReturnsObject(method, 2)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id WAGRHostUserContext(UIViewController *host, id suppliedContext) {
    if (suppliedContext) return suppliedContext;
    for (NSString *selectorName in @[
        @"userContext", @"wa_userContext", @"currentUserContext", @"context"
    ]) {
        id value = WAGRCallZeroArgumentObject(host, selectorName);
        if (value) return value;
    }
    @try {
        id value = [host valueForKey:@"userContext"];
        if (value) return value;
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static id WAGRObjectFromContext(id context, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        id value = WAGRCallZeroArgumentObject(context, selectorName);
        if (value) return value;
    }
    return nil;
}

static id WAGRResolveABPropertiesObject(id userContext) {
    id object = WAGRObjectFromContext(userContext, @[
        @"abProperties", @"waABProperties", @"properties", @"serverProperties"
    ]);
    if (object) return object;

    for (id candidate in WAGRABPropsResolveRuntimeObjects(userContext)) {
        NSString *name = NSStringFromClass([candidate class]).lowercaseString ?: @"";
        if ([name containsString:@"abpropert"] ||
            [name containsString:@"foawaab"] ||
            [name containsString:@"wapropert"]) {
            return candidate;
        }
    }
    return nil;
}

static id WAGRResolveDebugOverridesObject(id userContext) {
    return WAGRObjectFromContext(userContext, @[
        @"debugPropOverrides", @"debugOverrides", @"privateABProperties"
    ]);
}

static BOOL WAGRClassIsUIViewControllerSubclass(Class cls) {
    if (!cls) return NO;
    Class current = cls;
    while (current) {
        if (current == UIViewController.class) return YES;
        current = class_getSuperclass(current);
    }
    return NO;
}

static BOOL WAGRClassLooksLikeABPropsController(Class cls) {
    if (!WAGRClassIsUIViewControllerSubclass(cls)) return NO;
    NSString *name = NSStringFromClass(cls) ?: @"";
    NSString *lower = name.lowercaseString;
    if ([lower hasPrefix:@"wagr"] || [lower containsString:@"privateexperimentation"]) return NO;
    BOOL properties = [lower containsString:@"abproperties"] ||
                      [lower containsString:@"abprops"] ||
                      ([lower containsString:@"ab"] && [lower containsString:@"propert"]);
    BOOL controller = [lower containsString:@"controller"] ||
                      [lower containsString:@"tableview"];
    return properties && controller;
}

static BOOL WAGRSelectorLooksLikeABPropsControllerFactory(NSString *selectorName) {
    if (!selectorName.length) return NO;
    NSString *lower = selectorName.lowercaseString;
    if ([lower hasPrefix:@"set"] || [lower hasPrefix:@"reset"] ||
        [lower hasPrefix:@"clear"] || [lower hasPrefix:@"remove"] ||
        [lower hasPrefix:@"delete"]) return NO;
    BOOL properties = [lower containsString:@"abproperties"] ||
                      [lower containsString:@"abprops"] ||
                      ([lower containsString:@"ab"] && [lower containsString:@"propert"]);
    BOOL controller = [lower containsString:@"viewcontroller"] ||
                      [lower containsString:@"controller"] ||
                      [lower containsString:@"tableview"];
    return properties && controller;
}

static id WAGRArgumentForSelectorLabel(NSString *label,
                                       id userContext,
                                       id abProperties,
                                       id debugOverrides) {
    NSString *lower = label.lowercaseString ?: @"";
    if ([lower containsString:@"usercontext"] ||
        ([lower containsString:@"context"] && ![lower containsString:@"controller"])) {
        return userContext;
    }
    if ([lower containsString:@"debugoverride"] || [lower containsString:@"propoverride"]) {
        return debugOverrides;
    }
    if ([lower containsString:@"abpropert"] || [lower containsString:@"abprops"] ||
        ([lower containsString:@"propert"] && ![lower containsString:@"controller"])) {
        return abProperties;
    }
    return nil;
}

static id WAGRInvokeObjectMethod(id target,
                                 Method method,
                                 SEL selector,
                                 id userContext,
                                 id abProperties,
                                 id debugOverrides) {
    if (!target || !method || !selector) return nil;
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount < 2 || argumentCount > 4) return nil;
    if (!WAGRMethodReturnsObject(method, argumentCount)) return nil;

    NSString *selectorName = NSStringFromSelector(selector);
    NSArray<NSString *> *labels = [selectorName componentsSeparatedByString:@":"];
    id args[2] = { nil, nil };
    for (unsigned int index = 0; index + 2 < argumentCount; index++) {
        NSString *label = index < labels.count ? labels[index] : @"";
        args[index] = WAGRArgumentForSelectorLabel(label, userContext,
                                                    abProperties, debugOverrides);
        if (!args[index]) return nil;
    }

    @try {
        switch (argumentCount) {
            case 2:
                return ((id (*)(id, SEL))objc_msgSend)(target, selector);
            case 3:
                return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, args[0]);
            case 4:
                return ((id (*)(id, SEL, id, id))objc_msgSend)(target, selector,
                                                               args[0], args[1]);
            default:
                return nil;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIViewController *WAGRFactoryControllerFromTarget(id target,
                                                          BOOL classMethods,
                                                          id userContext,
                                                          id abProperties,
                                                          id debugOverrides,
                                                          NSString **source) {
    if (!target) return nil;
    Class owner = classMethods ? object_getClass((Class)target) : [target class];
    for (Class current = owner; current; current = class_getSuperclass(current)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(current, &methodCount);
        if (!methods) continue;
        for (unsigned int index = 0; index < methodCount; index++) {
            Method method = methods[index];
            SEL selector = method_getName(method);
            NSString *selectorName = NSStringFromSelector(selector);
            if (!WAGRSelectorLooksLikeABPropsControllerFactory(selectorName)) continue;
            id value = WAGRInvokeObjectMethod(target, method, selector, userContext,
                                              abProperties, debugOverrides);
            if ([value isKindOfClass:UIViewController.class]) {
                if (source) {
                    *source = [NSString stringWithFormat:@"%@%@.%@",
                        classMethods ? @"+" : @"-",
                        NSStringFromClass(classMethods ? (Class)target : [target class]),
                        selectorName];
                }
                free(methods);
                return value;
            }
        }
        free(methods);
    }
    return nil;
}

static NSArray<Class> *WAGRNativeABPropsControllerClasses(void) {
    NSMutableOrderedSet<Class> *classes = [NSMutableOrderedSet orderedSet];
    for (NSString *name in @[
        @"WADebugABPropertiesTableViewController",
        @"WADebugABPropsTableViewController",
        @"WAABPropertiesTableViewController",
        @"WAABPropsTableViewController"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (WAGRClassLooksLikeABPropsController(cls)) [classes addObject:cls];
    }

    unsigned int classCount = 0;
    __unsafe_unretained Class *runtimeClasses = objc_copyClassList(&classCount);
    for (unsigned int index = 0; index < classCount; index++) {
        Class cls = runtimeClasses[index];
        if (WAGRClassLooksLikeABPropsController(cls)) [classes addObject:cls];
    }
    free(runtimeClasses);
    return classes.array ?: @[];
}

static UIViewController *WAGRInstantiateControllerClass(Class cls,
                                                         id userContext,
                                                         id abProperties,
                                                         id debugOverrides,
                                                         NSString **source) {
    if (!WAGRClassLooksLikeABPropsController(cls)) return nil;
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    if (!allocated) return nil;

    NSArray<NSString *> *preferredInitializers = @[
        @"initWithUserContext:abProperties:",
        @"initWithABProperties:userContext:",
        @"initWithUserContext:properties:",
        @"initWithUserContext:",
        @"initWithABProperties:",
        @"initWithAbProperties:",
        @"initWithProperties:",
        @"init"
    ];

    for (NSString *selectorName in preferredInitializers) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        id value = WAGRInvokeObjectMethod(allocated, method, selector, userContext,
                                          abProperties, debugOverrides);
        if ([value isKindOfClass:UIViewController.class]) {
            if (source) *source = [NSString stringWithFormat:@"%@.%@",
                                   NSStringFromClass(cls), selectorName];
            return value;
        }
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int index = 0; index < methodCount; index++) {
        Method method = methods[index];
        SEL selector = method_getName(method);
        NSString *selectorName = NSStringFromSelector(selector);
        if (![selectorName hasPrefix:@"initWith"]) continue;
        id value = WAGRInvokeObjectMethod(allocated, method, selector, userContext,
                                          abProperties, debugOverrides);
        if ([value isKindOfClass:UIViewController.class]) {
            if (source) *source = [NSString stringWithFormat:@"%@.%@",
                                   NSStringFromClass(cls), selectorName];
            free(methods);
            return value;
        }
    }
    free(methods);
    return nil;
}

UIViewController *WAGRResolveNativeABPropsController(UIViewController *host,
                                                      id userContext,
                                                      NSString **diagnostic) {
    if (!host) {
        NSString *text = @"host controller is nil";
        WAGRNativeABPropsSetDiagnostic(text);
        if (diagnostic) *diagnostic = text;
        return nil;
    }

    id context = WAGRHostUserContext(host, userContext);
    id abProperties = WAGRResolveABPropertiesObject(context);
    id debugOverrides = WAGRResolveDebugOverridesObject(context);

    NSMutableOrderedSet *targets = [NSMutableOrderedSet orderedSet];
    [targets addObject:host];
    if (context) [targets addObject:context];
    if (abProperties) [targets addObject:abProperties];
    if (debugOverrides) [targets addObject:debugOverrides];
    for (id object in WAGRABPropsResolveRuntimeObjects(context)) {
        if (object) [targets addObject:object];
    }
    id provider = WAGRObjectFromContext(context, @[
        @"debugMenuProvider", @"developerMenuProvider", @"debugMenuProviding"
    ]);
    if (provider) [targets addObject:provider];

    NSString *source = nil;
    for (id target in targets) {
        UIViewController *controller = WAGRFactoryControllerFromTarget(
            target, NO, context, abProperties, debugOverrides, &source);
        if (controller) {
            NSString *text = [NSString stringWithFormat:@"native factory %@", source ?: @"unknown"];
            WAGRNativeABPropsSetDiagnostic(text);
            if (diagnostic) *diagnostic = text;
            return controller;
        }
    }

    for (Class cls in WAGRNativeABPropsControllerClasses()) {
        UIViewController *controller = WAGRFactoryControllerFromTarget(
            (id)cls, YES, context, abProperties, debugOverrides, &source);
        if (controller) {
            NSString *text = [NSString stringWithFormat:@"native class factory %@", source ?: @"unknown"];
            WAGRNativeABPropsSetDiagnostic(text);
            if (diagnostic) *diagnostic = text;
            return controller;
        }
        controller = WAGRInstantiateControllerClass(cls, context, abProperties,
                                                    debugOverrides, &source);
        if (controller) {
            NSString *text = [NSString stringWithFormat:@"native controller %@", source ?: NSStringFromClass(cls)];
            WAGRNativeABPropsSetDiagnostic(text);
            if (diagnostic) *diagnostic = text;
            return controller;
        }
    }

    NSString *text = [NSString stringWithFormat:
        @"native AB Props controller/factory not loaded (context=%@ abProperties=%@ targets=%lu)",
        context ? NSStringFromClass([context class]) : @"nil",
        abProperties ? NSStringFromClass([abProperties class]) : @"nil",
        (unsigned long)targets.count];
    WAGRNativeABPropsSetDiagnostic(text);
    if (diagnostic) *diagnostic = text;
    return nil;
}
