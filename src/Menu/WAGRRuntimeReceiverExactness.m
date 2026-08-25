#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRSurface.h"

static NSArray *(*gWAGRRuntimeOriginalObjects)(id, SEL) = NULL;

static void WAGRRuntimeAddControllerTree(UIViewController *controller,
                                         NSMutableOrderedSet *objects,
                                         NSUInteger depth) {
    if (!controller || depth > 5) return;
    [objects addObject:controller];
    if (controller.isViewLoaded) [objects addObject:controller.view];
    if (controller.presentedViewController)
        WAGRRuntimeAddControllerTree(controller.presentedViewController, objects, depth + 1);
    for (UIViewController *child in controller.childViewControllers)
        WAGRRuntimeAddControllerTree(child, objects, depth + 1);
}

static NSArray *WAGRRuntimeResolvedObjects(id self, SEL _cmd) {
    NSMutableOrderedSet *objects = [NSMutableOrderedSet orderedSet];
    if (gWAGRRuntimeOriginalObjects) {
        for (id object in gWAGRRuntimeOriginalObjects(self, _cmd))
            if (object) [objects addObject:object];
    }
    UIApplication *app = UIApplication.sharedApplication;
    if (app.delegate) [objects addObject:app.delegate];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                [objects addObject:window];
                WAGRRuntimeAddControllerTree(window.rootViewController, objects, 0);
            }
        }
    }
    return objects.array ?: @[];
}

static BOOL WAGRRuntimeFactoryReturnsObject(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = raw;
    while (*type && strchr("rnNoORV", *type)) type++;
    return *type == '@';
}

static id WAGRRuntimeExactReceiver(id self, SEL _cmd, WAGREntry *entry) {
    (void)_cmd;
    if (!entry || entry.isClassMethod) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    if (!cls) return nil;
    SEL selector = NSSelectorFromString(entry.selectorName);
    NSArray *objects = nil;
    @try { objects = [self valueForKey:@"runtimeObjects"]; }
    @catch (__unused NSException *exception) { objects = @[]; }

    for (id object in objects ?: @[]) {
        if ([object isKindOfClass:cls] && [object respondsToSelector:selector]) return object;
    }

    // Only ask the declaring class for conventional singleton accessors. Never
    // bind a same-named selector to an unrelated object.
    for (NSString *factoryName in @[@"shared", @"sharedInstance", @"current",
                                     @"defaultInstance", @"defaultManager",
                                     @"manager", @"provider", @"properties"]) {
        SEL factory = NSSelectorFromString(factoryName);
        Method method = class_getClassMethod(cls, factory);
        if (!WAGRRuntimeFactoryReturnsObject(method)) continue;
        @try {
            id candidate = ((id (*)(id, SEL))objc_msgSend)((id)cls, factory);
            if ([candidate isKindOfClass:cls] && [candidate respondsToSelector:selector]) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void WAGRRuntimeReceiverInstall(void) {
    Class cls = NSClassFromString(@"WAGRSurfaceBrowserVC");
    if (!cls) return;
    Method objects = class_getInstanceMethod(cls, NSSelectorFromString(@"resolveRuntimeObjects"));
    if (objects && method_getImplementation(objects) != (IMP)WAGRRuntimeResolvedObjects) {
        gWAGRRuntimeOriginalObjects = (NSArray *(*)(id, SEL))method_getImplementation(objects);
        method_setImplementation(objects, (IMP)WAGRRuntimeResolvedObjects);
    }
    Method receiver = class_getInstanceMethod(cls, NSSelectorFromString(@"receiverForEntry:"));
    if (receiver && method_getImplementation(receiver) != (IMP)WAGRRuntimeExactReceiver) {
        method_setImplementation(receiver, (IMP)WAGRRuntimeExactReceiver);
    }
}

__attribute__((constructor))
static void WAGRRuntimeReceiverCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRRuntimeReceiverInstall(); });
    }
}
