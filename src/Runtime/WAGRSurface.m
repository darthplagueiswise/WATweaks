#import "WAGRSurface.h"
#import "WAGRRuntimeValueStore.h"
#import "WAGRRuntimeSafety.h"
#import "WAGRWAABFamilyCatalog.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <stdlib.h>

@implementation WAGREntry
@end

@implementation WAGRSurfaceSpec

+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces {
    return [WAGRScanner runtimeImageSurfaces];
}

@end

static NSArray<WAGRSurfaceSpec *> *gWAGRImageSurfaceCache = nil;
static NSArray<Class> *gWAGRAppClassCache = nil;
static uint32_t gWAGRImageSurfaceCacheGeneration = UINT32_MAX;
static uint32_t gWAGRAppClassCacheGeneration = UINT32_MAX;

static NSObject *WAGRLiveCacheLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static uint32_t WAGRLiveImageGeneration(void) {
    return _dyld_image_count();
}

#pragma mark - Live naming

NSString *WAGRCleanDisplayName(NSString *name) {
    if (!name.length) return @"";
    NSString *value = [name copy];
    while ([value hasPrefix:@"@property "]) value = [value substringFromIndex:10];
    while ([value hasPrefix:@"- "]) value = [value substringFromIndex:2];
    while ([value hasPrefix:@"+ "]) value = [value substringFromIndex:2];
    return value;
}

static NSString *WAGRLiveCanonicalImagePath(NSString *path) {
    if (!path.length) return @"";
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSString *cached = cache[path];
        if (cached) return cached;
    }
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    @synchronized (cache) { cache[path] = resolved; }
    return resolved;
}

static BOOL WAGRRuntimePathIsAppOwned(NSString *path) {
    if (!path.length) return NO;
    NSString *bundle = NSBundle.mainBundle.bundlePath ?: @"";
    return WAGRRuntimePathIsWithinBundleCString(WAGRLiveCanonicalImagePath(path).UTF8String,
                                                WAGRLiveCanonicalImagePath(bundle).UTF8String);
}

static NSString *WAGRLiveRelativeImagePath(NSString *path) {
    NSString *bundle = NSBundle.mainBundle.bundlePath ?: @"";
    if (!WAGRRuntimePathIsWithinBundleCString(path.UTF8String, bundle.UTF8String)) {
        path = WAGRLiveCanonicalImagePath(path);
        bundle = WAGRLiveCanonicalImagePath(bundle);
    }
    if (bundle.length && path.length > bundle.length &&
        WAGRRuntimePathIsWithinBundleCString(path.UTF8String, bundle.UTF8String)) {
        return [path substringFromIndex:bundle.length + 1];
    }
    return path;
}

static NSArray<NSString *> *WAGRLiveAppImagePaths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *rawPath = _dyld_get_image_name(index);
        NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
        if (WAGRRuntimePathIsAppOwned(path)) [paths addObject:WAGRLiveCanonicalImagePath(path)];
    }
    return paths.array;
}

static NSArray<NSString *> *WAGRLiveBundledImagePaths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    NSString *bundlePath = WAGRLiveCanonicalImagePath(NSBundle.mainBundle.bundlePath);
    NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath isDirectory:YES];
    NSString *executable = NSBundle.mainBundle.executablePath;
    if (WAGRRuntimeFileIsMachOCString(executable.fileSystemRepresentation)) {
        [paths addObject:WAGRLiveCanonicalImagePath(executable)];
    }
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:bundleURL includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
            return YES;
        }];
    for (NSURL *url in enumerator) {
        NSNumber *directory = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        NSString *relativePath = WAGRLiveRelativeImagePath(url.path);
        if (!WAGRRuntimeBundledPathIsInspectableCString(relativePath.UTF8String)) {
            if (directory.boolValue) [enumerator skipDescendants];
            continue;
        }
        NSString *candidate = nil;
        if (directory.boolValue && [url.pathExtension isEqualToString:@"framework"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]];
            NSString *name = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class]
                ? [info[@"CFBundleExecutable"] lastPathComponent] : url.lastPathComponent.stringByDeletingPathExtension;
            if (name.length) candidate = [url.path stringByAppendingPathComponent:name];
            // Descend into nested frameworks, including Watusi/FLEX and InMobi.
        } else if (!directory.boolValue && [url.pathExtension isEqualToString:@"dylib"]) {
            candidate = url.path;
        }
        if (WAGRRuntimePathIsAppOwned(candidate) &&
            WAGRRuntimeFileIsMachOCString(candidate.fileSystemRepresentation)) {
            [paths addObject:WAGRLiveCanonicalImagePath(candidate)];
        }
    }
    return paths.array;
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

static NSString *WAGRLiveHeuristicFamilyForSelector(NSString *selectorName, NSString *className) {
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

NSString *WAGRLiveRuntimeFamilyForSelector(NSString *selectorName, NSString *className) {
    return WAGRLiveRuntimeFamilyForSelectorInImage(selectorName, className, nil);
}

NSString *WAGRLiveRuntimeFamilyForSelectorInImage(NSString *selectorName,
                                                    NSString *className,
                                                    NSString *imagePath) {
    NSString *fallback = WAGRLiveHeuristicFamilyForSelector(selectorName, className);
    return WAGRWAABFamilyForSelector(selectorName, imagePath, fallback, NULL);
}

NSString *WAGRLiveRuntimeSubcategoryForEntry(NSString *selectorName,
                                              NSString *className,
                                              NSString *imagePath) {
    NSString *family = WAGRLiveRuntimeFamilyForSelectorInImage(selectorName, className, imagePath);
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
    uint32_t generation = WAGRLiveImageGeneration();
    @synchronized (WAGRLiveCacheLock()) {
        if (gWAGRAppClassCache && gWAGRAppClassCacheGeneration == generation) {
            return gWAGRAppClassCache;
        }
    }
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
    NSArray<Class> *snapshot = [classes copy];
    @synchronized (WAGRLiveCacheLock()) {
        if (generation == WAGRLiveImageGeneration()) {
            gWAGRAppClassCache = snapshot;
            gWAGRAppClassCacheGeneration = generation;
        }
    }
    return snapshot;
}

static BOOL WAGRLiveMethodIsSupported(Method method, NSString **selectorName, NSString **typeCode) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    NSString *selector = NSStringFromSelector(method_getName(method));
    if (!WAGRRuntimeValueSelectorIsSafeGetter(selector)) return NO;
    char rawType[64] = {0};
    method_getReturnType(method, rawType, sizeof(rawType));
    NSString *type = [NSString stringWithUTF8String:rawType] ?: @"";
    if (!WAGRRuntimeValueTypeIsSupported(type)) return NO;
    if (selectorName) *selectorName = selector;
    if (typeCode) *typeCode = type;
    return YES;
}

static NSString *WAGRLiveMethodImagePath(Method method, Class fallbackClass) {
    IMP implementation = method ? method_getImplementation(method) : NULL;
    Dl_info info = {0};
    if (implementation && dladdr((const void *)implementation, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        if (path.length) return WAGRLiveCanonicalImagePath(path);
    }
    const char *rawPath = fallbackClass ? class_getImageName(fallbackClass) : NULL;
    NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
    return WAGRLiveCanonicalImagePath(path);
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
    uint32_t generation = WAGRLiveImageGeneration();
    @synchronized (WAGRLiveCacheLock()) {
        if (gWAGRImageSurfaceCache && gWAGRImageSurfaceCacheGeneration == generation) {
            return gWAGRImageSurfaceCache;
        }
    }
    @autoreleasepool {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSString *path in WAGRLiveBundledImagePaths()) {
        groups[path] = [@{ @"classes": [NSMutableSet set], @"methods": @0, @"loaded": @NO } mutableCopy];
    }
    // Image presence is independent of Objective-C getter eligibility.
    for (NSString *path in WAGRLiveAppImagePaths()) {
        groups[path] = [@{ @"classes": [NSMutableSet set], @"methods": @0, @"loaded": @YES } mutableCopy];
    }
    for (Class cls in WAGRLiveAppClasses()) {
        NSString *className = NSStringFromClass(cls) ?: @"Unknown";
        const char *rawPath = class_getImageName(cls);
        NSString *classPath = WAGRLiveCanonicalImagePath(rawPath ? [NSString stringWithUTF8String:rawPath] : @"");
        if (groups[classPath]) [groups[classPath][@"classes"] addObject:className];
        for (NSUInteger meta = 0; meta <= 1; meta++) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(meta ? object_getClass(cls) : cls, &count);
            for (unsigned int index = 0; index < count; index++) {
                Method method = methods[index];
                if (!WAGRLiveMethodIsSupported(method, NULL, NULL)) continue;
                NSString *path = WAGRLiveMethodImagePath(method, cls);
                if (!WAGRRuntimePathIsAppOwned(path)) continue;
                NSMutableDictionary *group = groups[path];
                if (!group) {
                    group = [@{ @"classes": [NSMutableSet set], @"methods": @0, @"loaded": @YES } mutableCopy];
                    groups[path] = group;
                }
                group[@"loaded"] = @YES;
                [group[@"classes"] addObject:className];
                group[@"methods"] = @([group[@"methods"] unsignedIntegerValue] + 1);
            }
            free(methods);
        }
    }

    NSMutableArray<WAGRSurfaceSpec *> *surfaces = [NSMutableArray array];
    [groups enumerateKeysAndObjectsUsingBlock:^(NSString *path, NSMutableDictionary *group, BOOL *stop) {
        (void)stop;
        NSUInteger classCount = [group[@"classes"] count];
        NSUInteger methodCount = [group[@"methods"] unsignedIntegerValue];
        BOOL loaded = [group[@"loaded"] boolValue];
        NSString *name = WAGRLiveRuntimeImageNameForPath(path);
        NSString *relativePath = WAGRLiveRelativeImagePath(path);
        NSString *subtitle = loaded
            ? [NSString stringWithFormat:@"%@\nCarregada · %lu classes ObjC · %lu getters editáveis",
                relativePath, (unsigned long)classCount, (unsigned long)methodCount]
            : [NSString stringWithFormat:@"%@\nNo bundle · não carregada", relativePath];
        NSString *identifier = [@"image:" stringByAppendingString:relativePath];
        NSString *icon = [name containsString:@"Executable"] ? @"app.dashed" : @"shippingbox";
        WAGRSurfaceSpec *surface = WAGRLiveSurface(identifier, name, subtitle, icon);
        surface.runtimeImagePath = path;
        surface.runtimeImageLoaded = loaded;
        surface.runtimeClassCount = classCount;
        surface.runtimeEntryCount = methodCount;
        [surfaces addObject:surface];
    }];

    [surfaces sortUsingComparator:^NSComparisonResult(WAGRSurfaceSpec *left, WAGRSurfaceSpec *right) {
        BOOL leftExec = [left.title containsString:@"Executable"];
        BOOL rightExec = [right.title containsString:@"Executable"];
        if (leftExec != rightExec) return leftExec ? NSOrderedAscending : NSOrderedDescending;
        if (left.runtimeImageLoaded != right.runtimeImageLoaded) return left.runtimeImageLoaded ? NSOrderedAscending : NSOrderedDescending;
        if (left.runtimeEntryCount != right.runtimeEntryCount) {
            return left.runtimeEntryCount > right.runtimeEntryCount ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    NSArray<WAGRSurfaceSpec *> *snapshot = [surfaces copy];
    @synchronized (WAGRLiveCacheLock()) {
        if (generation == WAGRLiveImageGeneration()) {
            gWAGRImageSurfaceCache = snapshot;
            gWAGRImageSurfaceCacheGeneration = generation;
        }
    }
    return snapshot;
    }
}

+ (NSArray<WAGRSurfaceSpec *> *)runtimeFamilySurfaces {
    @autoreleasepool {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (Class cls in WAGRLiveAppClasses()) {
        NSString *className = NSStringFromClass(cls) ?: @"Unknown";
        for (NSUInteger meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(cls) : cls;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(owner, &count);
            if (!methods) continue;
            for (unsigned int index = 0; index < count; index++) {
                NSString *selector = nil;
                Method method = methods[index];
                if (!WAGRLiveMethodIsSupported(method, &selector, NULL)) continue;
                NSString *methodPath = WAGRLiveMethodImagePath(method, cls);
                NSString *family = WAGRLiveRuntimeFamilyForSelectorInImage(selector, className, methodPath);
                if (!family.length) continue;
                NSMutableDictionary *group = groups[family];
                if (!group) {
                    group = [@{ @"classes": [NSMutableSet set], @"images": [NSMutableSet set], @"methods": @0 } mutableCopy];
                    groups[family] = group;
                }
                [group[@"classes"] addObject:className];
                if (methodPath.length) [group[@"images"] addObject:methodPath];
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
    return [surfaces copy];
    }
}

+ (void)invalidateRuntimeImageCache {
    @synchronized (WAGRLiveCacheLock()) {
        gWAGRImageSurfaceCache = nil;
        gWAGRImageSurfaceCacheGeneration = UINT32_MAX;
        gWAGRAppClassCache = nil;
        gWAGRAppClassCacheGeneration = UINT32_MAX;
    }
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

    // A category may contribute methods from a different Mach-O than the class.
    // WAGRAddEntry checks exact image membership from the resolved method IMP.
    if (spec.runtimeImagePath.length) return WAGRRuntimePathIsAppOwned(path);
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
    Method method = meta ? class_getClassMethod(cls, NSSelectorFromString(selector))
                         : class_getInstanceMethod(cls, NSSelectorFromString(selector));
    NSString *imagePath = WAGRLiveMethodImagePath(method, cls);
    if (!WAGRRuntimeMethodMatchesImageCString(imagePath.UTF8String,
                                               spec.runtimeImagePath.UTF8String)) return;
    NSString *imageName = WAGRLiveRuntimeImageNameForPath(imagePath);
    NSString *family = WAGRLiveRuntimeFamilyForSelectorInImage(selector, className, imagePath);
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
    if (spec.runtimeImagePath.length) {
        spec.runtimeImageLoaded = [WAGRLiveAppImagePaths() containsObject:spec.runtimeImagePath];
        if (!spec.runtimeImageLoaded) return @[];
    }
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
