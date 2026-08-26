#import "WAGRABPropsRuntime.h"
#import "WAGRRuntimeClassifier.h"
#import "WAGRRuntimeValueStore.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdlib.h>
#include <string.h>

extern id WAGRCurrentUserContext(void);

@implementation WAGRABPropEntry
@end

static NSDictionary *gWAGRABLiveStats = nil;
static NSObject *gWAGRABLiveStatsLock = nil;

static NSString *WAGRABNormalizedType(NSString *typeCode) {
    if (!typeCode.length) return @"";
    const char *cursor = typeCode.UTF8String;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor ? [NSString stringWithFormat:@"%c", *cursor] : @"";
}

static id WAGRABCallObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char type[32] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (![WAGRABNormalizedType([NSString stringWithUTF8String:type] ?: @"")
          isEqualToString:@"@"]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WAGRABObjectLooksRelevant(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]).lowercaseString ?: @"";
    if ([name containsString:@"abpropert"] ||
        [name containsString:@"privateexperiment"] ||
        [name containsString:@"serverpropert"] ||
        [name containsString:@"foawaab"] ||
        [name containsString:@"wapropert"] ||
        [name containsString:@"propoverride"] ||
        [name containsString:@"debugoverride"]) {
        return YES;
    }
    return [object respondsToSelector:NSSelectorFromString(@"isMetaEmployeeOrInternalTester")] ||
           [object respondsToSelector:NSSelectorFromString(@"waios_mc_debug_ui_enabled")] ||
           [object respondsToSelector:NSSelectorFromString(@"boolForKey:defaultValue:")];
}

static void WAGRABCollectObjectGraph(id root,
                                      NSMutableOrderedSet *objects,
                                      NSMutableSet<NSValue *> *visited,
                                      NSUInteger depth) {
    if (!root || depth > 3) return;
    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if (WAGRABObjectLooksRelevant(root)) [objects addObject:root];

    for (NSString *selectorName in @[
        @"abProperties", @"waABProperties", @"privateABProperties",
        @"serverProperties", @"debugPropOverrides", @"properties",
        @"propertiesStore", @"experimentProperties", @"mobileConfig",
        @"mobileConfigManager", @"preferences", @"preferencesStore",
        @"accountProvider", @"userContext"
    ]) {
        id child = WAGRABCallObject(root, selectorName);
        if (!child || child == root) continue;
        if (WAGRABObjectLooksRelevant(child)) [objects addObject:child];
        WAGRABCollectObjectGraph(child, objects, visited, depth + 1);
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
        char type[32] = {0};
        method_getReturnType(method, type, sizeof(type));
        if (![WAGRABNormalizedType([NSString stringWithUTF8String:type] ?: @"")
              isEqualToString:@"@"]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
            if (value) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

NSArray *WAGRABPropsResolveRuntimeObjects(id userContext) {
    NSMutableOrderedSet *objects = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    id context = userContext ?: WAGRCurrentUserContext();
    WAGRABCollectObjectGraph(context, objects, visited, 0);

    for (NSString *name in @[
        @"WAABProperties", @"WAProperties", @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl", @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties",
        @"WAPrivateExperimentation.PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        id shared = WAGRABSharedObjectForClass(cls);
        if (shared) [objects addObject:shared];
    }

    WAGRLogAppendF(@"[ABProps] resolved runtimeObjects=%lu context=%@",
                   (unsigned long)objects.count,
                   context ? NSStringFromClass([context class]) : @"nil");
    return objects.array ?: @[];
}

NSDictionary *WAGRABPropsCatalogStats(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRABLiveStatsLock = [NSObject new];
    });
    @synchronized (gWAGRABLiveStatsLock) {
        return [gWAGRABLiveStats copy] ?: @{};
    }
}

static NSString *WAGRABImageForMethod(Method method, Class baseClass) {
    if (method) {
        Dl_info info = {0};
        IMP implementation = method_getImplementation(method);
        if (implementation && dladdr((const void *)implementation, &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
            if ([path containsString:@"SharedModules.framework/SharedModules"]) return @"SharedModules";
            if ([path hasSuffix:@"/WhatsApp"] || [path isEqualToString:@"WhatsApp"]) return @"WhatsApp";
            return path.lastPathComponent.length ? path.lastPathComponent : path;
        }
    }
    const char *image = class_getImageName(baseClass);
    NSString *path = image ? [NSString stringWithUTF8String:image] : @"";
    return path.lastPathComponent.length ? path.lastPathComponent : @"runtime";
}

static NSArray<Class> *WAGRABClassesToScan(NSArray *runtimeObjects) {
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];
    for (id object in runtimeObjects) {
        Class cls = [object class];
        while (cls && cls != NSObject.class) {
            NSString *name = NSStringFromClass(cls).lowercaseString ?: @"";
            if ([name containsString:@"abpropert"] ||
                [name containsString:@"privateexperiment"] ||
                [name containsString:@"serverpropert"] ||
                [name containsString:@"foawaab"] ||
                [name containsString:@"wapropert"] ||
                [name containsString:@"propoverride"]) {
                [classes addObject:cls];
            }
            cls = class_getSuperclass(cls);
        }
    }

    for (NSString *name in @[
        @"WAABProperties", @"WAProperties", @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl", @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties",
        @"WAPrivateExperimentation.PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (cls) [classes addObject:cls];
    }
    return classes.array ?: @[];
}

static BOOL WAGRABValidateMethod(Class cls,
                                  NSString *selectorName,
                                  BOOL classMethod,
                                  Method *outMethod,
                                  NSString **outType,
                                  NSString **outEncoding) {
    if (!cls || !selectorName.length) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod ? class_getClassMethod(cls, selector)
                                : class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char rawReturn[64] = {0};
    method_getReturnType(method, rawReturn, sizeof(rawReturn));
    NSString *runtimeType = WAGRABNormalizedType(
        [NSString stringWithUTF8String:rawReturn] ?: @"");
    if (!WAGRRuntimeValueTypeIsSupported(runtimeType)) return NO;

    if (outMethod) *outMethod = method;
    if (outType) *outType = runtimeType;
    if (outEncoding) {
        const char *encoding = method_getTypeEncoding(method);
        *outEncoding = encoding ? [NSString stringWithUTF8String:encoding] : @"";
    }
    return YES;
}

static void WAGRABAppendEntry(NSMutableArray<WAGRABPropEntry *> *entries,
                               NSMutableSet<NSString *> *seen,
                               Class cls,
                               NSString *selectorName,
                               BOOL classMethod) {
    Method method = NULL;
    NSString *runtimeType = nil;
    NSString *encoding = nil;
    if (!WAGRABValidateMethod(cls, selectorName, classMethod,
                              &method, &runtimeType, &encoding)) return;

    NSString *className = NSStringFromClass(cls) ?: @"";
    NSString *uid = WAGRRuntimeValueUID(className, selectorName, classMethod);
    if (!uid.length || [seen containsObject:uid]) return;
    [seen addObject:uid];

    WAGRABPropEntry *entry = [WAGRABPropEntry new];
    entry.className = className;
    entry.selectorName = selectorName;
    entry.typeCode = runtimeType;
    entry.typeName = WAGRRuntimeValueTypeName(runtimeType) ?: runtimeType;
    entry.categoryName = WAGRLiveRuntimeFamilyForSelector(selectorName, className);
    entry.sourceImage = WAGRABImageForMethod(method, cls);
    entry.methodEncoding = encoding ?: @"";
    entry.classMethod = classMethod;
    entry.cataloged = NO;
    [entries addObject:entry];
}

NSArray<WAGRABPropEntry *> *WAGRABPropsScan(NSArray *runtimeObjects) {
    NSMutableArray<WAGRABPropEntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *typeCounts = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *images = [NSMutableSet set];
    NSArray<Class> *classes = WAGRABClassesToScan(runtimeObjects);

    for (Class baseClass in classes) {
        for (NSUInteger meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(baseClass) : baseClass;
            if (!owner) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            if (!methods) continue;
            for (unsigned int index = 0; index < methodCount; index++) {
                Method method = methods[index];
                if (!method || method_getNumberOfArguments(method) != 2) continue;
                NSString *selectorName = NSStringFromSelector(method_getName(method));
                if (!selectorName.length || [selectorName containsString:@":"]) continue;
                NSUInteger before = entries.count;
                WAGRABAppendEntry(entries, seen, baseClass, selectorName, (BOOL)meta);
                if (entries.count > before) {
                    WAGRABPropEntry *entry = entries.lastObject;
                    typeCounts[entry.typeCode] = @([typeCounts[entry.typeCode] unsignedIntegerValue] + 1);
                    if (entry.sourceImage.length) [images addObject:entry.sourceImage];
                }
            }
            free(methods);
        }
    }

    NSArray *sorted = [entries sortedArrayUsingComparator:
        ^NSComparisonResult(WAGRABPropEntry *left, WAGRABPropEntry *right) {
            NSComparisonResult result = [left.categoryName
                localizedCaseInsensitiveCompare:right.categoryName];
            if (result != NSOrderedSame) return result;
            result = [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
            if (result != NSOrderedSame) return result;
            return [left.sourceImage localizedCaseInsensitiveCompare:right.sourceImage];
        }];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRABLiveStatsLock = [NSObject new];
    });
    NSDictionary *stats = @{
        @"source" : @"live Objective-C runtime",
        @"classes" : @(classes.count),
        @"selectors" : @(sorted.count),
        @"images" : @(images.count),
        @"return_type_counts" : [typeCounts copy],
    };
    @synchronized (gWAGRABLiveStatsLock) {
        gWAGRABLiveStats = stats;
    }

    WAGRLogAppendF(@"[ABProps] live selectors=%lu classes=%lu images=%lu runtimeObjects=%lu",
                   (unsigned long)sorted.count,
                   (unsigned long)classes.count,
                   (unsigned long)images.count,
                   (unsigned long)runtimeObjects.count);
    return sorted;
}

id WAGRABPropsReceiverForEntry(WAGRABPropEntry *entry, NSArray *runtimeObjects) {
    if (!entry) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    if (entry.classMethod) return cls && [cls respondsToSelector:selector] ? cls : nil;
    if (!cls) return nil;
    for (id object in runtimeObjects) {
        if (![object isKindOfClass:cls]) continue;
        if ([object respondsToSelector:selector]) return object;
    }
    return nil;
}

NSString *WAGRABPropsCurrentValue(WAGRABPropEntry *entry,
                                   NSArray *runtimeObjects,
                                   id *rawValue) {
    if (!entry) {
        if (rawValue) *rawValue = nil;
        return @"entrada inválida";
    }
    return WAGRRuntimeValueRead(entry.className,
                                entry.selectorName,
                                entry.classMethod,
                                WAGRABPropsReceiverForEntry(entry, runtimeObjects),
                                rawValue);
}
