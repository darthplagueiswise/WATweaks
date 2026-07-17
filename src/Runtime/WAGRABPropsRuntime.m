#import "WAGRABPropsRuntime.h"
#import "WAGRRuntimeClassifier.h"
#import "WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdlib.h>

@implementation WAGRABPropEntry
@end

static NSString * const kWAGRABCatalogFilename = @"WAABProperties.json";

static id WAGRABCallObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != '@') return nil;
    @try {
        IMP implementation = [object methodForSelector:selector];
        return implementation ? ((id (*)(id, SEL))implementation)(object, selector) : nil;
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

    NSArray<NSString *> *selectors = @[
        @"abProperties", @"waABProperties", @"privateABProperties",
        @"serverProperties", @"debugPropOverrides", @"properties",
        @"experimentProperties", @"mobileConfig", @"mobileConfigManager",
        @"preferences", @"preferencesStore", @"accountProvider", @"userContext"
    ];
    for (NSString *selectorName in selectors) {
        id value = WAGRABCallObject(root, selectorName);
        if (!value || value == root) continue;
        if (WAGRABObjectLooksRelevant(value)) [objects addObject:value];
        WAGRABCollectObjectGraph(value, objects, visited, depth + 1);
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
            IMP implementation = [cls methodForSelector:selector];
            id value = implementation ? ((id (*)(id, SEL))implementation)(cls, selector) : nil;
            if (value) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

NSArray *WAGRABPropsResolveRuntimeObjects(id userContext) {
    NSMutableOrderedSet *objects = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    WAGRABCollectObjectGraph(userContext, objects, visited, 0);

    for (NSString *name in @[
        @"WAABProperties",
        @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl",
        @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties",
        @"WAPrivateExperimentation.PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        id shared = WAGRABSharedObjectForClass(cls);
        if (shared) [objects addObject:shared];
    }
    return objects.array ?: @[];
}

static NSArray<NSString *> *WAGRABCatalogCandidatePaths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    NSArray<NSString *> *roots = @[
        @"/var/jb/Library/Application Support/WATweaks/runtime",
        @"/Library/Application Support/WATweaks/runtime",
        @"/var/mobile/Library/Application Support/WATweaks/runtime"
    ];
    for (NSString *root in roots) {
        [paths addObject:[root stringByAppendingPathComponent:kWAGRABCatalogFilename]];
    }
    NSBundle *bundle = [NSBundle bundleForClass:NSClassFromString(@"WAABProperties") ?: NSObject.class];
    NSString *bundlePath = [bundle pathForResource:@"WAABProperties" ofType:@"json"];
    if (bundlePath.length) [paths addObject:bundlePath];
    return paths.array;
}

static NSDictionary *WAGRABCatalog(void) {
    static NSDictionary *catalog = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *path in WAGRABCatalogCandidatePaths()) {
            NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            if (!data.length) continue;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:NSDictionary.class]) continue;
            if ([json[@"schema_version"] integerValue] < 3) continue;
            catalog = json;
            break;
        }
        if (!catalog) catalog = @{};
    });
    return catalog;
}

NSDictionary *WAGRABPropsCatalogStats(void) {
    NSDictionary *catalog = WAGRABCatalog();
    id stats = catalog[@"stats"];
    if ([stats isKindOfClass:NSDictionary.class]) return stats;

    NSNumber *categories = catalog[@"categories_total"];
    NSNumber *methods = catalog[@"methods_total"];
    NSNumber *selectors = catalog[@"selectors_unique"];
    NSDictionary *types = [catalog[@"return_type_counts"] isKindOfClass:NSDictionary.class]
        ? catalog[@"return_type_counts"] : @{};
    if (!categories && !methods && !selectors) return @{};
    return @{
        @"categories_total": categories ?: @0,
        @"methods_supported": methods ?: @0,
        @"selectors_supported": selectors ?: @0,
        @"return_type_counts": types
    };
}

static NSDictionary *WAGRABMetadataForSelector(NSString *selectorName) {
    if (!selectorName.length) return @{};
    NSDictionary *catalog = WAGRABCatalog();
    id rawMetadata = [catalog[@"selectors"] isKindOfClass:NSDictionary.class]
        ? catalog[@"selectors"][selectorName] : nil;
    NSArray *metadata = [rawMetadata isKindOfClass:NSArray.class] ? rawMetadata : nil;
    NSArray *categories = [catalog[@"categories"] isKindOfClass:NSArray.class]
        ? catalog[@"categories"] : @[];

    if (metadata.count >= 4 && [metadata[0] respondsToSelector:@selector(integerValue)]) {
        NSInteger categoryIndex = [metadata[0] integerValue];
        NSString *category = (categoryIndex >= 0 && categoryIndex < (NSInteger)categories.count)
            ? categories[(NSUInteger)categoryIndex]
            : @"WAABProperties";
        NSInteger imageCode = [metadata[1] integerValue];
        NSString *image = imageCode == 0 ? @"WhatsApp" : @"SharedModules";
        NSString *type = [metadata[2] isKindOfClass:NSString.class] ? metadata[2] : @"";
        BOOL meta = [metadata[3] boolValue];
        return @{ @"category": category ?: @"WAABProperties",
                  @"image": image,
                  @"type": type,
                  @"meta": @(meta) };
    }

    NSString *runtimeSection = WAGRRuntimeSectionForSelector(selectorName, @"WAABProperties");
    return @{ @"category": runtimeSection.length ? runtimeSection : @"Other — General" };
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

static NSArray *WAGRABClassesToScan(NSArray *runtimeObjects) {
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];
    for (id object in runtimeObjects) {
        Class cls = [object class];
        while (cls && cls != NSObject.class) {
            NSString *name = NSStringFromClass(cls).lowercaseString ?: @"";
            if ([name containsString:@"abpropert"] ||
                [name containsString:@"privateexperiment"] ||
                [name containsString:@"serverpropert"] ||
                [name containsString:@"foawaab"] ||
                [name containsString:@"propoverride"]) {
                [classes addObject:cls];
            }
            cls = class_getSuperclass(cls);
        }
    }

    for (NSString *name in @[
        @"WAABProperties",
        @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl",
        @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties",
        @"WAPrivateExperimentation.PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (cls) [classes addObject:cls];
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

                NSDictionary *metadata = WAGRABMetadataForSelector(selectorName);
                WAGRABPropEntry *entry = [WAGRABPropEntry new];
                entry.className = className;
                entry.selectorName = selectorName;
                entry.typeCode = typeCode;
                entry.typeName = typeName;
                entry.classMethod = (BOOL)meta;
                entry.categoryName = metadata[@"category"] ?: WAGRRuntimeSectionForSelector(selectorName, className);
                entry.sourceImage = metadata[@"image"] ?: WAGRABImageForMethod(method, baseClass);
                [entries addObject:entry];
            }
            free(methods);
        }
    }

    return [entries sortedArrayUsingComparator:^NSComparisonResult(WAGRABPropEntry *left,
                                                                    WAGRABPropEntry *right) {
        NSComparisonResult result = [left.categoryName localizedCaseInsensitiveCompare:right.categoryName];
        if (result != NSOrderedSame) return result;
        result = [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
        if (result != NSOrderedSame) return result;
        return [left.className localizedCaseInsensitiveCompare:right.className];
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
