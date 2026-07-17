#import "WAGRSurface.h"
#import "WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#include <stdlib.h>

@implementation WAGREntry
@end

@implementation WAGRSurfaceSpec

+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces {
    return [WAGRScanner runtimeImageSurfaces];
}

@end

#pragma mark - Live naming

NSString *WAGRCleanDisplayName(NSString *name) {
    if (!name.length) return @"";
    NSString *value = [name copy];
    while ([value hasPrefix:@"@property "]) value = [value substringFromIndex:10];
    while ([value hasPrefix:@"- "]) value = [value substringFromIndex:2];
    while ([value hasPrefix:@"+ "]) value = [value substringFromIndex:2];
    return value;
}

static BOOL WAGRRuntimePathIsAppOwned(NSString *path) {
    if (!path.length) return NO;
    NSString *bundle = NSBundle.mainBundle.bundlePath ?: @"";
    if (bundle.length && [path hasPrefix:bundle]) return YES;
    return [path rangeOfString:@"/WhatsApp.app/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

NSString *WAGRLiveRuntimeImageNameForPath(NSString *imagePath) {
    if (!imagePath.length) return @"Runtime";
    if ([imagePath hasSuffix:@"/WhatsApp"] || [imagePath isEqualToString:@"WhatsApp"]) {
        return @"WhatsApp Executable";
    }
    NSArray<NSString *> *parts = imagePath.pathComponents;
    for (NSString *part in [parts reverseObjectEnumerator]) {
        if ([part hasSuffix:@".framework"]) return part;
    }
    NSString *last = imagePath.lastPathComponent;
    return last.length ? last : imagePath;
}

static NSArray<NSString *> *WAGRLiveRawTokens(NSString *value) {
    if (!value.length) return @[];
    NSMutableString *expanded = [NSMutableString stringWithCapacity:value.length * 2];
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;

    unichar previous = 0;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar current = [value characterAtIndex:index];
        BOOL isUpper = [upper characterIsMember:current];
        BOOL previousLower = previous && [lower characterIsMember:previous];
        if (isUpper && previousLower) [expanded appendString:@"_"];
        if ([alnum characterIsMember:current]) [expanded appendFormat:@"%C", current];
        else [expanded appendString:@"_"];
        previous = current;
    }

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [expanded.lowercaseString componentsSeparatedByString:@"_"]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

static NSSet<NSString *> *WAGRLiveStopWords(void) {
    static NSSet<NSString *> *words = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = [NSSet setWithArray:@[
            @"is", @"has", @"have", @"can", @"could", @"should", @"would",
            @"get", @"set", @"for", @"from", @"with", @"without", @"and", @"or",
            @"the", @"of", @"to", @"a", @"an", @"value", @"flag", @"feature",
            @"enabled", @"enable", @"disabled", @"disable", @"active", @"available",
            @"availability", @"launched", @"launch", @"supported", @"support",
            @"ios", @"waios", @"waio", @"objc", @"impl", @"implementation",
            @"property", @"properties", @"provider", @"manager"
        ]];
    });
    return words;
}

static NSString *WAGRLiveDisplayToken(NSString *token) {
    if (!token.length) return @"";
    static NSSet<NSString *> *acronyms = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        acronyms = [NSSet setWithArray:@[
            @"ai", @"ab", @"mc", @"ui", @"ux", @"api", @"qpl", @"foa", @"wds",
            @"wa", @"m0", @"m1", @"m2", @"md", @"voip", @"upi", @"pix", @"br"
        ]];
    });
    if ([acronyms containsObject:token]) return token.uppercaseString;
    return token.localizedCapitalizedString;
}

NSString *WAGRLiveRuntimeFamilyForSelector(NSString *selectorName, NSString *className) {
    NSArray<NSString *> *source = WAGRLiveRawTokens(selectorName.length ? selectorName : className);
    NSMutableArray<NSString *> *meaningful = [NSMutableArray array];
    NSSet<NSString *> *stop = WAGRLiveStopWords();
    for (NSString *token in source) {
        if ([stop containsObject:token]) continue;
        if ([token rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound &&
            [token rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == NSNotFound) continue;
        [meaningful addObject:token];
        if (meaningful.count == 3) break;
    }
    if (!meaningful.count) {
        for (NSString *token in source) {
            if (token.length) { [meaningful addObject:token]; break; }
        }
    }
    if (!meaningful.count && className.length) {
        NSArray *classTokens = WAGRLiveRawTokens(className);
        for (NSString *token in classTokens) {
            if (![stop containsObject:token]) [meaningful addObject:token];
            if (meaningful.count == 3) break;
        }
    }
    if (!meaningful.count) return @"Other Runtime";

    NSMutableArray<NSString *> *display = [NSMutableArray arrayWithCapacity:meaningful.count];
    for (NSString *token in meaningful) [display addObject:WAGRLiveDisplayToken(token)];
    return [display componentsJoinedByString:@" "];
}

NSString *WAGRLiveRuntimeSubcategoryForEntry(NSString *selectorName,
                                              NSString *className,
                                              NSString *imagePath) {
    NSString *family = WAGRLiveRuntimeFamilyForSelector(selectorName, className);
    NSString *owner = className.length ? className : WAGRLiveRuntimeImageNameForPath(imagePath);
    NSString *ownerLower = owner.lowercaseString ?: @"";
    BOOL genericABOwner = [ownerLower containsString:@"waabproperties"] ||
                          [ownerLower containsString:@"foawaabproperties"];
    if (genericABOwner || !owner.length) return family;
    return [NSString stringWithFormat:@"%@ — %@", owner, family];
}

NSString *WAGRCategoryForSelector(NSString *selectorName) {
    return WAGRLiveRuntimeFamilyForSelector(selectorName, nil);
}

#pragma mark - Snapshot helpers

static NSArray<Class> *WAGRLiveAppClasses(void) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (!list || !count) {
        if (list) free(list);
        return @[];
    }
    NSMutableArray<Class> *classes = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        Class cls = list[index];
        const char *rawPath = cls ? class_getImageName(cls) : NULL;
        NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
        if (WAGRRuntimePathIsAppOwned(path)) [classes addObject:cls];
    }
    free(list);
    return classes;
}

static BOOL WAGRLiveMethodIsSupported(Method method, NSString **selectorName, NSString **typeCode) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    NSString *selector = NSStringFromSelector(method_getName(method));
    if (!selector.length || [selector containsString:@":"]) return NO;
    char rawType[64] = {0};
    method_getReturnType(method, rawType, sizeof(rawType));
    NSString *type = [NSString stringWithUTF8String:rawType] ?: @"";
    if (!WAGRRuntimeValueTypeIsSupported(type)) return NO;
    if (selectorName) *selectorName = selector;
    if (typeCode) *typeCode = type;
    return YES;
}

static NSUInteger WAGRLiveSupportedMethodCount(Class cls) {
    if (!cls) return 0;
    NSUInteger total = 0;
    for (NSUInteger meta = 0; meta <= 1; meta++) {
        Class owner = meta ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(owner, &count);
        if (!methods) continue;
        for (unsigned int index = 0; index < count; index++) {
            if (WAGRLiveMethodIsSupported(methods[index], NULL, NULL)) total++;
        }
        free(methods);
    }
    return total;
}

static WAGRSurfaceSpec *WAGRLiveSurface(NSString *identifier,
                                        NSString *title,
                                        NSString *subtitle,
                                        NSString *icon) {
    WAGRSurfaceSpec *surface = [WAGRSurfaceSpec new];
    surface.surfaceID = identifier ?: @"runtime";
    surface.title = title ?: @"Runtime";
    surface.subtitle = subtitle ?: @"";
    surface.icon = icon ?: @"circle";
    surface.classNames = @[];
    surface.classNameFragments = @[];
    surface.selectorTokens = @[];
    surface.categoryAllowList = @[];
    surface.scanInstanceMethods = YES;
    surface.scanClassMethods = YES;
    surface.scanProperties = YES;
    surface.advancedOnly = YES;
    surface.runtimeGenerated = YES;
    return surface;
}

@implementation WAGRScanner

+ (NSArray<WAGRSurfaceSpec *> *)runtimeImageSurfaces {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (Class cls in WAGRLiveAppClasses()) {
        NSUInteger methods = WAGRLiveSupportedMethodCount(cls);
        if (!methods) continue;
        const char *rawPath = class_getImageName(cls);
        NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
        if (!path.length) continue;
        NSMutableDictionary *group = groups[path];
        if (!group) {
            group = [@{ @"classes": [NSMutableSet set], @"methods": @0 } mutableCopy];
            groups[path] = group;
        }
        [group[@"classes"] addObject:NSStringFromClass(cls) ?: @"Unknown"];
        group[@"methods"] = @([group[@"methods"] unsignedIntegerValue] + methods);
    }

    NSMutableArray<WAGRSurfaceSpec *> *surfaces = [NSMutableArray array];
    [groups enumerateKeysAndObjectsUsingBlock:^(NSString *path, NSMutableDictionary *group, BOOL *stop) {
        (void)stop;
        NSUInteger classCount = [group[@"classes"] count];
        NSUInteger methodCount = [group[@"methods"] unsignedIntegerValue];
        NSString *name = WAGRLiveRuntimeImageNameForPath(path);
        NSString *subtitle = [NSString stringWithFormat:@"%lu classes · %lu getters tipados carregados agora",
            (unsigned long)classCount, (unsigned long)methodCount];
        NSString *identifier = [NSString stringWithFormat:@"image:%lu", (unsigned long)path.hash];
        NSString *icon = [name containsString:@"Executable"] ? @"app.dashed" : @"shippingbox";
        WAGRSurfaceSpec *surface = WAGRLiveSurface(identifier, name, subtitle, icon);
        surface.runtimeImagePath = path;
        surface.runtimeClassCount = classCount;
        surface.runtimeEntryCount = methodCount;
        [surfaces addObject:surface];
    }];

    [surfaces sortUsingComparator:^NSComparisonResult(WAGRSurfaceSpec *left, WAGRSurfaceSpec *right) {
        BOOL leftExec = [left.title containsString:@"Executable"];
        BOOL rightExec = [right.title containsString:@"Executable"];
        if (leftExec != rightExec) return leftExec ? NSOrderedAscending : NSOrderedDescending;
        if (left.runtimeEntryCount != right.runtimeEntryCount) {
            return left.runtimeEntryCount > right.runtimeEntryCount ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    return surfaces;
}

+ (NSArray<WAGRSurfaceSpec *> *)runtimeFamilySurfaces {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (Class cls in WAGRLiveAppClasses()) {
        NSString *className = NSStringFromClass(cls) ?: @"Unknown";
        const char *rawPath = class_getImageName(cls);
        NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
        for (NSUInteger meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(cls) : cls;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(owner, &count);
            if (!methods) continue;
            for (unsigned int index = 0; index < count; index++) {
                NSString *selector = nil;
                if (!WAGRLiveMethodIsSupported(methods[index], &selector, NULL)) continue;
                NSString *family = WAGRLiveRuntimeFamilyForSelector(selector, className);
                if (!family.length) continue;
                NSMutableDictionary *group = groups[family];
                if (!group) {
                    group = [@{ @"classes": [NSMutableSet set], @"images": [NSMutableSet set], @"methods": @0 } mutableCopy];
                    groups[family] = group;
                }
                [group[@"classes"] addObject:className];
                if (path.length) [group[@"images"] addObject:path];
                group[@"methods"] = @([group[@"methods"] unsignedIntegerValue] + 1);
            }
            free(methods);
        }
    }

    NSMutableArray<WAGRSurfaceSpec *> *surfaces = [NSMutableArray array];
    [groups enumerateKeysAndObjectsUsingBlock:^(NSString *family, NSMutableDictionary *group, BOOL *stop) {
        (void)stop;
        NSUInteger classCount = [group[@"classes"] count];
        NSUInteger imageCount = [group[@"images"] count];
        NSUInteger methodCount = [group[@"methods"] unsignedIntegerValue];
        NSString *subtitle = [NSString stringWithFormat:@"%lu getters · %lu classes · %lu imagens carregadas agora",
            (unsigned long)methodCount, (unsigned long)classCount, (unsigned long)imageCount];
        NSString *identifier = [NSString stringWithFormat:@"family:%lu", (unsigned long)family.hash];
        WAGRSurfaceSpec *surface = WAGRLiveSurface(identifier, family, subtitle,
                                                   @"line.3.horizontal.decrease.circle");
        surface.runtimeFamilyKey = family;
        surface.runtimeClassCount = classCount;
        surface.runtimeEntryCount = methodCount;
        [surfaces addObject:surface];
    }];

    [surfaces sortUsingComparator:^NSComparisonResult(WAGRSurfaceSpec *left, WAGRSurfaceSpec *right) {
        if (left.runtimeEntryCount != right.runtimeEntryCount) {
            return left.runtimeEntryCount > right.runtimeEntryCount ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    return surfaces;
}

static BOOL WAGRTokenMatch(NSArray<NSString *> *tokens, NSString *haystack) {
    if (!tokens.count) return YES;
    NSString *lower = haystack.lowercaseString ?: @"";
    for (NSString *token in tokens) {
        if (token.length && [lower containsString:token.lowercaseString]) return YES;
    }
    return NO;
}

static BOOL WAGRClassMatchesSurface(WAGRSurfaceSpec *spec, Class cls) {
    if (!spec || !cls) return NO;
    NSString *className = NSStringFromClass(cls) ?: @"";
    const char *rawPath = class_getImageName(cls);
    NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";

    if (spec.runtimeImagePath.length) return [path isEqualToString:spec.runtimeImagePath];
    if (spec.runtimeFamilyKey.length) return WAGRRuntimePathIsAppOwned(path);

    for (NSString *name in spec.classNames) {
        if ([className isEqualToString:name]) return YES;
    }
    for (NSString *fragment in spec.classNameFragments) {
        if (fragment.length && [className rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return !spec.classNames.count && !spec.classNameFragments.count && WAGRRuntimePathIsAppOwned(path);
}

static void WAGRAddEntry(NSMutableArray<WAGREntry *> *output,
                         NSMutableSet<NSString *> *seen,
                         WAGRSurfaceSpec *spec,
                         Class cls,
                         BOOL meta,
                         NSString *selector,
                         BOOL property,
                         NSString *typeCode) {
    if (!selector.length || [selector containsString:@":"] || !typeCode.length) return;
    NSString *typeName = WAGRRuntimeValueTypeName(typeCode);
    if (!typeName.length) return;
    NSString *className = NSStringFromClass(cls);
    if (!className.length) return;
    const char *rawPath = class_getImageName(cls);
    NSString *imagePath = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
    NSString *imageName = WAGRLiveRuntimeImageNameForPath(imagePath);
    NSString *family = WAGRLiveRuntimeFamilyForSelector(selector, className);
    if (spec.runtimeFamilyKey.length && ![family isEqualToString:spec.runtimeFamilyKey]) return;

    NSString *display = WAGRCleanDisplayName(selector);
    NSString *subcategory = WAGRLiveRuntimeSubcategoryForEntry(selector, className, imagePath);
    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@",
        imageName, className, selector, display, typeName, family, subcategory];
    if (!WAGRTokenMatch(spec.selectorTokens, haystack)) return;
    if (spec.categoryAllowList.count && !WAGRTokenMatch(spec.categoryAllowList, haystack)) return;

    NSString *uid = WAGRRuntimeValueUID(className, selector, meta);
    if (!uid.length || [seen containsObject:uid]) return;
    [seen addObject:uid];

    WAGREntry *entry = [WAGREntry new];
    entry.surfaceID = spec.surfaceID ?: @"runtime";
    entry.className = className;
    entry.isClassMethod = meta;
    entry.isProperty = property;
    entry.selectorName = selector;
    entry.displayName = display.length ? display : selector;
    entry.returnType = typeName;
    entry.typeCode = typeCode;
    entry.typeName = typeName;
    entry.overrideKey = uid;
    entry.imagePath = imagePath;
    entry.imageName = imageName;
    entry.runtimeFamily = family;
    entry.runtimeSubcategory = subcategory;
    entry.category = imageName;
    [output addObject:entry];
}

+ (NSArray<WAGREntry *> *)scanSurface:(WAGRSurfaceSpec *)spec {
    if (!spec) return @[];
    NSMutableArray<WAGREntry *> *output = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (Class cls in WAGRLiveAppClasses()) {
        if (!WAGRClassMatchesSurface(spec, cls)) continue;

        if (spec.scanProperties) {
            unsigned int propertyCount = 0;
            objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
            if (properties) {
                for (unsigned int index = 0; index < propertyCount; index++) {
                    const char *rawName = property_getName(properties[index]);
                    if (!rawName) continue;
                    NSString *selector = [NSString stringWithUTF8String:rawName];
                    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selector));
                    NSString *liveSelector = nil;
                    NSString *typeCode = nil;
                    if (!WAGRLiveMethodIsSupported(method, &liveSelector, &typeCode)) continue;
                    WAGRAddEntry(output, seen, spec, cls, NO, liveSelector, YES, typeCode);
                }
                free(properties);
            }
        }

        for (NSUInteger meta = 0; meta <= 1; meta++) {
            if (meta == 0 && !spec.scanInstanceMethods) continue;
            if (meta == 1 && !spec.scanClassMethods) continue;
            Class owner = meta ? object_getClass(cls) : cls;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            if (!methods) continue;
            for (unsigned int index = 0; index < methodCount; index++) {
                NSString *selector = nil;
                NSString *typeCode = nil;
                if (!WAGRLiveMethodIsSupported(methods[index], &selector, &typeCode)) continue;
                WAGRAddEntry(output, seen, spec, cls, (BOOL)meta, selector, NO, typeCode);
            }
            free(methods);
        }
    }

    return [output sortedArrayUsingComparator:^NSComparisonResult(WAGREntry *left, WAGREntry *right) {
        NSComparisonResult result = [left.runtimeFamily localizedCaseInsensitiveCompare:right.runtimeFamily];
        if (result != NSOrderedSame) return result;
        result = [left.imageName localizedCaseInsensitiveCompare:right.imageName];
        if (result != NSOrderedSame) return result;
        result = [left.className localizedCaseInsensitiveCompare:right.className];
        if (result != NSOrderedSame) return result;
        result = [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
        if (result != NSOrderedSame) return result;
        return left.isClassMethod == right.isClassMethod ? NSOrderedSame
            : (left.isClassMethod ? NSOrderedAscending : NSOrderedDescending);
    }];
}

@end
