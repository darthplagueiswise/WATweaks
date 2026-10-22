#import "WAGRWAABFamilyCatalog.h"
#import "WAGRWAABCatalogPolicy.h"

static NSDictionary *gWAGRWAABFamilyCatalog = nil;
static NSString *gWAGRWAABFamilyCatalogPath = nil;
static NSString *gWAGRWAABFamilyCatalogRejection = nil;

static NSDictionary *WAGRLoadWAABFamilyCatalog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *paths = @[
            @"/var/jb/Library/Application Support/WATweaks/waab_family_catalog_26_40_10.json",
            @"/Library/Application Support/WATweaks/waab_family_catalog_26_40_10.json",
            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"waab_family_catalog_26_40_10.json"]
        ];
        for (NSString *path in paths) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data.length) continue;
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![object isKindOfClass:NSDictionary.class]) continue;
            NSString *catalogVersion = [object[@"whatsappVersion"] isKindOfClass:NSString.class]
                ? object[@"whatsappVersion"] : @"";
            NSString *catalogBuild = [object[@"build"] isKindOfClass:NSString.class]
                ? object[@"build"] : @"";
            NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
            NSString *runningVersion = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
                ? info[@"CFBundleShortVersionString"] : @"";
            NSString *runningBuild = [info[@"CFBundleVersion"] isKindOfClass:NSString.class]
                ? info[@"CFBundleVersion"] : @"";
            if (!WAGRWAABCatalogBuildMatchesCString(catalogVersion.UTF8String,
                                                     catalogBuild.UTF8String,
                                                     runningVersion.UTF8String,
                                                     runningBuild.UTF8String)) {
                gWAGRWAABFamilyCatalogRejection = [NSString stringWithFormat:
                    @"catalog %@ (%@) != running %@ (%@)",
                    catalogVersion, catalogBuild, runningVersion, runningBuild];
                continue;
            }
            NSDictionary *selectors = [object[@"selectors"] isKindOfClass:NSDictionary.class]
                ? object[@"selectors"] : nil;
            if (!selectors.count) continue;
            gWAGRWAABFamilyCatalog = object;
            gWAGRWAABFamilyCatalogPath = path;
            break;
        }
    });
    return gWAGRWAABFamilyCatalog ?: @{};
}

static NSArray<NSString *> *WAGRStringArray(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableOrderedSet<NSString *> *strings = [NSMutableOrderedSet orderedSet];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:NSString.class] && [item length]) [strings addObject:item];
    }
    return strings.array;
}

NSString *WAGRWAABFamilyForSelector(NSString *selectorName,
                                     NSString *sourceImage,
                                     NSString *fallback,
                                     BOOL *cataloged) {
    if (cataloged) *cataloged = NO;
    NSDictionary *catalog = WAGRLoadWAABFamilyCatalog();
    NSDictionary *selectors = [catalog[@"selectors"] isKindOfClass:NSDictionary.class]
        ? catalog[@"selectors"] : @{};
    NSDictionary *record = [selectors[selectorName ?: @""] isKindOfClass:NSDictionary.class]
        ? selectors[selectorName ?: @""] : nil;
    NSMutableOrderedSet<NSString *> *families = [NSMutableOrderedSet orderedSet];

    if (WAGRWAABCatalogMayUseImageCString(sourceImage.UTF8String, 1)) {
        [families addObjectsFromArray:WAGRStringArray(record[@"SharedModules"])];
    }
    if (WAGRWAABCatalogMayUseImageCString(sourceImage.UTF8String, 2)) {
        [families addObjectsFromArray:WAGRStringArray(record[@"WhatsApp"])];
    }
    if (families.count) {
        if (cataloged) *cataloged = YES;
        return [families.array componentsJoinedByString:@" / "];
    }
    NSString *name = fallback.length ? fallback : @"Other Runtime";
    if ([name hasPrefix:@"Fallback · "]) return name;
    return [@"Fallback · " stringByAppendingString:name];
}

NSString *WAGRWAABFamilyCatalogDiagnosticText(void) {
    NSDictionary *catalog = WAGRLoadWAABFamilyCatalog();
    NSDictionary *selectors = [catalog[@"selectors"] isKindOfClass:NSDictionary.class]
        ? catalog[@"selectors"] : @{};
    return [NSString stringWithFormat:@"build=%@\nversion=%@\nselectors=%lu\npath=%@\nrejection=%@",
            catalog[@"build"] ?: @"unavailable",
            catalog[@"whatsappVersion"] ?: @"unavailable",
            (unsigned long)selectors.count,
            gWAGRWAABFamilyCatalogPath ?: @"not loaded",
            gWAGRWAABFamilyCatalogRejection ?: @"none"];
}
