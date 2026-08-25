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

static BOOL WAGRRuntimeObjectIsTraversalLeaf(id object) {
    if (!object) return YES;
    return [object isKindOfClass:NSString.class] ||
           [object isKindOfClass:NSNumber.class] ||
           [object isKindOfClass:NSData.class] ||
           [object isKindOfClass:NSDate.class] ||
           [object isKindOfClass:NSURL.class] ||
           [object isKindOfClass:NSValue.class];
}

static void WAGRRuntimeCollectCollectionChildren(id object,
                                                  NSMutableArray *queue,
                                                  NSUInteger limit) {
    if (!object || queue.count >= limit) return;
    const NSUInteger perCollectionLimit = 96;
    if ([object isKindOfClass:NSArray.class]) {
        NSUInteger count = MIN([(NSArray *)object count], perCollectionLimit);
        for (NSUInteger i = 0; i < count && queue.count < limit; i++) {
            id child = [(NSArray *)object objectAtIndex:i];
            if (child) [queue addObject:child];
        }
        return;
    }
    if ([object isKindOfClass:NSSet.class]) {
        NSUInteger added = 0;
        for (id child in (NSSet *)object) {
            if (child) [queue addObject:child];
            if (++added >= perCollectionLimit || queue.count >= limit) break;
        }
        return;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSUInteger added = 0;
        for (id child in [(NSDictionary *)object allValues]) {
            if (child) [queue addObject:child];
            if (++added >= perCollectionLimit || queue.count >= limit) break;
        }
    }
}

static void WAGRRuntimeCollectObjectIvars(id object,
                                          NSMutableArray *queue,
                                          NSUInteger limit) {
    if (!object || queue.count >= limit || WAGRRuntimeObjectIsTraversalLeaf(object)) return;
    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class] ||
        [object isKindOfClass:NSDictionary.class]) {
        WAGRRuntimeCollectCollectionChildren(object, queue, limit);
        return;
    }

    // A bounded object-ivar walk gives the runtime browser access to service /
    // dependency objects retained by the live app graph without scanning the
    // heap or fabricating instances. Only Objective-C object ivars are touched.
    Class cls = object_getClass(object);
    for (NSUInteger inheritanceDepth = 0;
         cls && inheritanceDepth < 7 && queue.count < limit;
         inheritanceDepth++, cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count && queue.count < limit; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            @try {
                id child = object_getIvar(object, ivars[i]);
                if (child && child != object) [queue addObject:child];
            } @catch (__unused NSException *exception) {}
        }
        free(ivars);
    }
}

static void WAGRRuntimeExpandBoundedGraph(NSMutableOrderedSet *objects) {
    const NSUInteger objectLimit = 1800;
    const NSUInteger depthLimit = 3;
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    for (id root in objects.array) {
        if (queue.count >= objectLimit) break;
        [queue addObject:@{ @"object": root, @"depth": @0 }];
    }

    NSUInteger cursor = 0;
    while (cursor < queue.count && objects.count < objectLimit) {
        NSDictionary *node = queue[cursor++];
        id object = node[@"object"];
        NSUInteger depth = [node[@"depth"] unsignedIntegerValue];
        if (!object || [objects containsObject:object]) {
            // Roots are already present but still need one expansion pass.
            if (depth != 0) continue;
        } else {
            [objects addObject:object];
        }
        if (depth >= depthLimit || WAGRRuntimeObjectIsTraversalLeaf(object)) continue;

        NSMutableArray *children = [NSMutableArray array];
        WAGRRuntimeCollectObjectIvars(object, children, 160);
        for (id child in children) {
            if (!child || [objects containsObject:child] || queue.count >= objectLimit) continue;
            [queue addObject:@{ @"object": child, @"depth": @(depth + 1) }];
        }
    }
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
    WAGRRuntimeExpandBoundedGraph(objects);
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
