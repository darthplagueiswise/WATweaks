#import "WAGRSurface.h"

// WAGRMainSettingsVC still asks for the historical IDs "exec" and
// "sharedmodules". The runtime scanner no longer creates fixed IDs: every
// surface is image:<hash> and is rebuilt from the currently loaded Mach-Os.
//
// Keep the callers working without restoring a static registry. These aliases
// are cloned from the live image surfaces every time +allSurfaces is requested.

static BOOL WAGRRuntimePathIsWhatsAppExecutable(NSString *path) {
    if (!path.length) return NO;
    BOOL executable = [path hasSuffix:@"/WhatsApp"] ||
                      [path isEqualToString:@"WhatsApp"] ||
                      [path rangeOfString:@"/WhatsApp.app/WhatsApp"
                                  options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL framework = [path rangeOfString:@".framework/"
                                  options:NSCaseInsensitiveSearch].location != NSNotFound;
    return executable && !framework;
}

static BOOL WAGRRuntimePathIsSharedModules(NSString *path) {
    if (!path.length) return NO;
    return [path rangeOfString:@"SharedModules.framework/SharedModules"
                       options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [path hasSuffix:@"/SharedModules"] ||
           [path isEqualToString:@"SharedModules"];
}

static WAGRSurfaceSpec *WAGRRuntimeAliasSurface(WAGRSurfaceSpec *source,
                                                 NSString *surfaceID) {
    if (!source || !surfaceID.length) return nil;

    WAGRSurfaceSpec *alias = [WAGRSurfaceSpec new];
    alias.surfaceID = surfaceID;
    alias.title = source.title ?: @"Runtime";
    alias.subtitle = source.subtitle ?: @"";
    alias.icon = source.icon ?: @"circle";
    alias.classNames = source.classNames ?: @[];
    alias.classNameFragments = source.classNameFragments ?: @[];
    alias.selectorTokens = source.selectorTokens ?: @[];
    alias.categoryAllowList = source.categoryAllowList ?: @[];
    alias.scanInstanceMethods = source.scanInstanceMethods;
    alias.scanClassMethods = source.scanClassMethods;
    alias.scanProperties = source.scanProperties;
    alias.advancedOnly = source.advancedOnly;
    alias.runtimeImagePath = source.runtimeImagePath;
    alias.runtimeFamilyKey = source.runtimeFamilyKey;
    alias.runtimeGenerated = YES;
    alias.runtimeClassCount = source.runtimeClassCount;
    alias.runtimeEntryCount = source.runtimeEntryCount;
    return alias;
}

%hook WAGRSurfaceSpec

+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces {
    NSArray<WAGRSurfaceSpec *> *live = [WAGRScanner runtimeImageSurfaces] ?: @[];
    NSMutableArray<WAGRSurfaceSpec *> *resolved = [live mutableCopy];

    WAGRSurfaceSpec *executable = nil;
    WAGRSurfaceSpec *sharedModules = nil;

    for (WAGRSurfaceSpec *surface in live) {
        NSString *path = surface.runtimeImagePath ?: @"";
        if (!executable && WAGRRuntimePathIsWhatsAppExecutable(path)) {
            executable = surface;
        }
        if (!sharedModules && WAGRRuntimePathIsSharedModules(path)) {
            sharedModules = surface;
        }
        if (executable && sharedModules) break;
    }

    // Insert aliases first so the existing helper resolves them immediately.
    if (sharedModules) {
        WAGRSurfaceSpec *alias = WAGRRuntimeAliasSurface(sharedModules, @"sharedmodules");
        if (alias) [resolved insertObject:alias atIndex:0];
    }
    if (executable) {
        WAGRSurfaceSpec *alias = WAGRRuntimeAliasSurface(executable, @"exec");
        if (alias) [resolved insertObject:alias atIndex:0];
    }

    return resolved;
}

%end
