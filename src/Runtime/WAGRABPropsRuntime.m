#import "WAGRABPropsRuntime.h"
#import "WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#include <stdlib.h>

@implementation WAGRABPropEntry
@end

static id WAGRABCallObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != '@') return nil;
    @try {
        IMP imp = [object methodForSelector:selector];
        return imp ? ((id (*)(id, SEL))imp)(object, selector) : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WAGRABObjectLooksLikeProperties(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]) ?: @"";
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"abpropert"] ||
        [lower containsString:@"privateexperiment"] ||
        [lower containsString:@"serverpropert"] ||
        [lower containsString:@"foawaab"]) {
        return YES;
    }
    return [object respondsToSelector:NSSelectorFromString(@"isMetaEmployeeOrInternalTester")] ||
           [object respondsToSelector:NSSelectorFromString(@"waios_mc_debug_ui_enabled")];
}

static void WAGRABCollectObjectGraph(id root,
                                     NSMutableOrderedSet *objects,
                                     NSUInteger depth) {
    if (!root || depth > 2) return;
    if (WAGRABObjectLooksLikeProperties(root)) [objects addObject:root];

    NSArray<NSString *> *selectors = @[
        @"abProperties", @"waABProperties", @"privateABProperties",
        @"serverProperties", @"properties", @"experimentProperties",
        @"mobileConfig", @"mobileConfigManager", @"preferences",
        @"preferencesStore", @"accountProvider", @"userContext"
    ];
    for (NSString *selectorName in selectors) {
        id value = WAGRABCallObject(root, selectorName);
        if (!value || value == root) continue;
        if (WAGRABObjectLooksLikeProperties(value)) [objects addObject:value];
        if (depth < 2 && ([selectorName containsString:@"Properties"] ||
                          [selectorName isEqualToString:@"accountProvider"] ||
                          [selectorName isEqualToString:@"userContext"])) {
            WAGRABCollectObjectGraph(value, objects, depth + 1);
        }
    }
}

static id WAGRABSharedObjectForClass(Class cls) {
    if (!cls) return nil;
    for (NSString *selectorName in @[
        @"shared", @"sharedInstance", @"current", @"defaultProperties",
        @"properties", @"serverProperties"
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getClassMethod(cls, selector);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char type[16] = {0};
        method_getReturnType(method, type, sizeof(type));
        if (type[0] != '@') continue;
        @try {
            IMP imp = [cls methodForSelector:selector];
            id value = imp ? ((id (*)(id, SEL))imp)(cls, selector) : nil;
            if (value) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

NSArray *WAGRABPropsResolveRuntimeObjects(id userContext) {
    NSMutableOrderedSet *objects = [NSMutableOrderedSet orderedSet];
    WAGRABCollectObjectGraph(userContext, objects, 0);

    for (NSString *name in @[
        @"WAABProperties",
        @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl",
        @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        id shared = WAGRABSharedObjectForClass(cls);
        if (shared) [objects addObject:shared];
    }
    return objects.array ?: @[];
}

static BOOL WAGRABClassNameMatches(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"abpropert"] ||
           [lower containsString:@"privateexperiment"] ||
           [lower containsString:@"serverpropert"] ||
           [lower containsString:@"foawaab"];
}

static NSArray *WAGRABClassesToScan(NSArray *runtimeObjects) {
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];
    for (id object in runtimeObjects) {
        Class cls = [object class];
        while (cls && cls != NSObject.class) {
            if (WAGRABClassNameMatches(NSStringFromClass(cls))) [classes addObject:cls];
            cls = class_getSuperclass(cls);
        }
    }

    for (NSString *name in @[
        @"WAABProperties", @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl", @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (cls) [classes addObject:cls];
    }

    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        __unsafe_unretained Class *all =
            (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
        if (all) {
            count = objc_getClassList(all, count);
            for (int index = 0; index < count; index++) {
                Class cls = all[index];
                if (cls && WAGRABClassNameMatches(NSStringFromClass(cls))) [classes addObject:cls];
            }
            free(all);
        }
    }
    return classes.array ?: @[];
}

NSArray<WAGRABPropEntry *> *WAGRABPropsScan(NSArray *runtimeObjects) {
    NSMutableArray<WAGRABPropEntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (Class baseClass in WAGRABClassesToScan(runtimeObjects)) {
        for (NSUInteger meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(baseClass) : baseClass;
            if (!owner) continue;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(owner, &count);
            if (!methods) continue;
            for (unsigned int index = 0; index < count; index++) {
                Method method = methods[index];
                if (!method || method_getNumberOfArguments(method) != 2) continue;
                NSString *selectorName = NSStringFromSelector(method_getName(method));
                if (!selectorName.length || [selectorName containsString:@":"]) continue;
                char returnType[64] = {0};
                method_getReturnType(method, returnType, sizeof(returnType));
                NSString *typeCode = [NSString stringWithUTF8String:returnType] ?: @"";
                NSString *typeName = WAGRRuntimeValueTypeName(typeCode);
                if (!typeName.length) continue;
                NSString *className = NSStringFromClass(baseClass) ?: @"";
                NSString *uid = WAGRRuntimeValueUID(className, selectorName, (BOOL)meta);
                if (!uid.length || [seen containsObject:uid]) continue;
                [seen addObject:uid];
                WAGRABPropEntry *entry = [WAGRABPropEntry new];
                entry.className = className;
                entry.selectorName = selectorName;
                entry.typeCode = typeCode;
                entry.typeName = typeName;
                entry.classMethod = (BOOL)meta;
                [entries addObject:entry];
            }
            free(methods);
        }
    }

    return [entries sortedArrayUsingComparator:^NSComparisonResult(WAGRABPropEntry *left,
                                                                    WAGRABPropEntry *right) {
        NSComparisonResult result = [left.className localizedCaseInsensitiveCompare:right.className];
        if (result != NSOrderedSame) return result;
        return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
    }];
}

id WAGRABPropsReceiverForEntry(WAGRABPropEntry *entry, NSArray *runtimeObjects) {
    if (!entry) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    if (entry.classMethod) return cls;
    SEL selector = NSSelectorFromString(entry.selectorName);
    for (id object in runtimeObjects) {
        if (cls && ![object isKindOfClass:cls]) continue;
        if ([object respondsToSelector:selector]) return object;
    }
    for (id object in runtimeObjects) {
        if ([object respondsToSelector:selector]) return object;
    }
    return nil;
}

NSString *WAGRABPropsCurrentValue(WAGRABPropEntry *entry,
                                  NSArray *runtimeObjects,
                                  id *rawValue) {
    id receiver = WAGRABPropsReceiverForEntry(entry, runtimeObjects);
    return WAGRRuntimeValueRead(entry.className,
                                entry.selectorName,
                                entry.classMethod,
                                receiver,
                                rawValue);
}
