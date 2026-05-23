#import "WAGRRuntimeInventory.h"
#import <objc/runtime.h>
#import <ctype.h>

static NSString *WAGRInvString(id obj) {
    return [obj isKindOfClass:NSString.class] ? (NSString *)obj : @"";
}

static NSArray<NSString *> *WAGRInvStringArray(id obj) {
    if (![obj isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id item in (NSArray *)obj) {
        if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    }
    return out;
}

static NSString *WAGRInvSlug(NSString *s) {
    if (!s.length) return @"inventory";
    NSMutableString *m = [NSMutableString string];
    NSCharacterSet *ok = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([ok characterIsMember:c]) [m appendFormat:@"%C", (unichar)tolower(c)];
        else if (m.length && ![m hasSuffix:@"_"]) [m appendString:@"_"];
    }
    while ([m hasSuffix:@"_"]) [m deleteCharactersInRange:NSMakeRange(m.length - 1, 1)];
    return m.length ? m : @"inventory";
}

static NSString *WAGRInvIconForFamily(NSString *family) {
    NSString *f = family.lowercaseString ?: @"";
    if ([f containsString:@"aura"]) return @"star";
    if ([f containsString:@"context"]) return @"point.3.connected.trianglepath.dotted";
    if ([f containsString:@"server"]) return @"server.rack";
    if ([f containsString:@"foa"]) return @"apps.iphone";
    if ([f containsString:@"biz"]) return @"briefcase";
    if ([f containsString:@"mobileconfig"]) return @"slider.horizontal.3";
    if ([f containsString:@"abproperties"]) return @"switch.2";
    return @"doc.text.magnifyingglass";
}

static NSArray<NSString *> *WAGRInvCandidateDirs(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    [dirs addObject:@"/var/jb/Library/Application Support/WATweaks/runtime"];
    [dirs addObject:@"/Library/Application Support/WATweaks/runtime"];

    NSString *bundleRuntime = [[NSBundle mainBundle] pathForResource:@"runtime" ofType:nil];
    if (bundleRuntime.length) [dirs addObject:bundleRuntime];

    NSString *bundleResource = [[NSBundle mainBundle] resourcePath];
    if (bundleResource.length) [dirs addObject:[bundleResource stringByAppendingPathComponent:@"runtime"]];

    return dirs;
}

static NSString *WAGRInvPathForFile(NSString *fileName) {
    if (!fileName.length) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in WAGRInvCandidateDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:fileName];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static NSDictionary *WAGRInvJSONAtPath(NSString *path) {
    if (!path.length) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:NSDictionary.class]) return nil;
    return (NSDictionary *)obj;
}

static NSDictionary<NSString *, NSDictionary *> *WAGRInvLoadAll(void) {
    NSMutableDictionary<NSString *, NSDictionary *> *out = [NSMutableDictionary dictionary];

    NSDictionary *manifest = WAGRInvJSONAtPath(WAGRInvPathForFile(@"manifest.json"));
    NSArray<NSString *> *files = WAGRInvStringArray(manifest[@"files"]);
    if (!files.count) {
        files = @[@"WAABProperties.json", @"WAContext.json", @"WAAura.json",
                  @"WAMobileConfig.json", @"WAFoa.json", @"WABiz.json",
                  @"WAServerProperties.json"];
    }

    if (manifest) out[@"manifest.json"] = manifest;
    for (NSString *file in files) {
        NSDictionary *json = WAGRInvJSONAtPath(WAGRInvPathForFile(file));
        if (json) out[file] = json;
    }
    return out;
}

static NSDictionary<NSString *, NSDictionary *> *WAGRInvCache(void) {
    static NSDictionary<NSString *, NSDictionary *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = WAGRInvLoadAll(); });
    return cache ?: @{};
}

static BOOL WAGRInvBoolNoArgMethod(Class cls, NSString *selector, BOOL meta) {
    if (!cls || !selector.length || [selector containsString:@":"]) return NO;
    SEL sel = NSSelectorFromString(selector);
    Method m = meta ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == 'B' || ret[0] == 'c';
}

static NSString *WAGRInvCategoryForGroups(NSArray<NSString *> *groups, NSString *fallback) {
    if (groups.count) {
        NSMutableArray<NSString *> *pretty = [NSMutableArray array];
        for (NSString *g in groups) {
            NSString *s = [[g stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
            if (s.length) [pretty addObject:s];
        }
        if (pretty.count) return [pretty componentsJoinedByString:@" / "];
    }
    return fallback.length ? fallback : @"Inventory";
}

static void WAGRInvAddEntry(NSMutableArray<WAGREntry *> *entries,
                            NSMutableSet<NSString *> *seen,
                            WAGRSurfaceSpec *spec,
                            NSString *className,
                            NSString *selector,
                            BOOL meta,
                            NSString *displayName,
                            NSString *category,
                            BOOL waabFlag,
                            NSString *source,
                            NSString *confidence) {
    if (!className.length || !selector.length) return;
    NSString *uid = [NSString stringWithFormat:@"%@|%@|%@", className, meta ? @"class" : @"inst", selector];
    if ([seen containsObject:uid]) return;
    [seen addObject:uid];

    WAGREntry *e = [WAGREntry new];
    e.surfaceID = spec.surfaceID ?: @"inventory";
    e.className = className;
    e.isClassMethod = meta;
    e.isProperty = NO;
    e.selectorName = selector;
    e.displayName = displayName.length ? displayName : WAGRCleanDisplayName(selector);
    e.returnType = @"BOOL";
    e.category = category.length ? category : WAGRCategoryForSelector([NSString stringWithFormat:@"%@ %@", className, selector]);
    e.overrideKey = WAGROverrideKey(e.surfaceID, className, meta, selector);
    e.inventoryBacked = YES;
    e.inventoryFile = spec.inventoryFile ?: @"";
    e.inventorySource = source ?: @"inventory";
    e.inventoryConfidence = confidence ?: @"";
    e.waabFlag = waabFlag;
    [entries addObject:e];
}

static void WAGRInvAddWAABFlags(NSMutableArray<WAGREntry *> *entries,
                                NSMutableSet<NSString *> *seen,
                                WAGRSurfaceSpec *spec,
                                NSArray *flags,
                                NSString *fallbackCategory) {
    if (![flags isKindOfClass:NSArray.class]) return;
    for (id item in flags) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *d = (NSDictionary *)item;
        NSString *key = WAGRInvString(d[@"key"]);
        if (!key.length) continue;
        NSString *title = WAGRInvString(d[@"title"]);
        NSArray<NSString *> *groups = WAGRInvStringArray(d[@"groups"]);
        NSString *category = WAGRInvCategoryForGroups(groups, fallbackCategory);
        WAGRInvAddEntry(entries, seen, spec, @"WAABProperties", key, NO,
                        title.length ? title : key, category, YES,
                        WAGRInvString(d[@"source"]), WAGRInvString(d[@"confidence"]));
    }
}

@implementation WAGRRuntimeInventory

+ (NSDictionary *)inventoryForFile:(NSString *)fileName {
    return WAGRInvCache()[fileName ?: @""] ?: @{};
}

+ (NSArray<WAGRSurfaceSpec *> *)inventorySurfaces {
    NSDictionary<NSString *, NSDictionary *> *all = WAGRInvCache();
    NSArray<NSString *> *order = @[@"WAABProperties.json", @"WAServerProperties.json", @"WAContext.json",
                                  @"WAAura.json", @"WAMobileConfig.json", @"WAFoa.json", @"WABiz.json"];
    NSMutableArray<WAGRSurfaceSpec *> *surfaces = [NSMutableArray array];

    for (NSString *file in order) {
        NSDictionary *json = all[file];
        if (![json isKindOfClass:NSDictionary.class]) continue;
        NSString *family = WAGRInvString(json[@"family"]);
        if (!family.length) family = [file stringByDeletingPathExtension];

        NSMutableArray<NSString *> *classNames = [NSMutableArray array];
        for (id obj in json[@"classes"]) {
            if (![obj isKindOfClass:NSDictionary.class]) continue;
            NSString *className = WAGRInvString(((NSDictionary *)obj)[@"class"]);
            if (className.length && ![classNames containsObject:className]) [classNames addObject:className];
        }

        NSMutableArray<NSString *> *frags = [NSMutableArray array];
        if ([family isEqualToString:@"FOA"]) [frags addObject:@"Foa"];
        else if (family.length) [frags addObject:family];
        if ([family isEqualToString:@"WAAura"]) [frags addObject:@"Aura"];
        if ([family isEqualToString:@"WABiz"]) [frags addObject:@"WABiz"];
        if ([family isEqualToString:@"WAContext"]) [frags addObject:@"ContextMain"];

        WAGRSurfaceSpec *s = [WAGRSurfaceSpec new];
        s.surfaceID = [@"inventory." stringByAppendingString:WAGRInvSlug(family)];
        s.title = [family isEqualToString:@"FOA"] ? @"FOA" : family;
        s.subtitle = WAGRInvString(json[@"grouping"]);
        s.icon = WAGRInvIconForFamily(family);
        s.classNames = classNames;
        s.classNameFragments = frags;
        s.selectorTokens = @[];
        s.categoryAllowList = @[];
        s.scanInstanceMethods = YES;
        s.scanClassMethods = YES;
        s.scanProperties = YES;
        s.advancedOnly = YES;
        s.inventoryBacked = YES;
        s.inventoryFile = file;
        s.inventoryFamily = family;
        s.inventoryMenuSections = WAGRInvStringArray(json[@"menu_sections"]);
        [surfaces addObject:s];
    }
    return surfaces;
}

+ (NSArray<WAGREntry *> *)inventoryEntriesForSurface:(WAGRSurfaceSpec *)spec {
    if (!spec.inventoryFile.length) return @[];
    NSDictionary *json = [self inventoryForFile:spec.inventoryFile];
    if (!json.count) return @[];

    NSMutableArray<WAGREntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *fallbackCategory = spec.inventoryFamily.length ? spec.inventoryFamily : @"Inventory";

    WAGRInvAddWAABFlags(entries, seen, spec, json[@"waab_flags"], fallbackCategory);
    WAGRInvAddWAABFlags(entries, seen, spec, json[@"waab_experiment_flags"], @"Experimentation");

    NSDictionary *selected = [json[@"selected_summaries"] isKindOfClass:NSDictionary.class] ? json[@"selected_summaries"] : nil;
    for (NSString *key in selected) WAGRInvAddWAABFlags(entries, seen, spec, selected[key], [key capitalizedString]);

    for (id obj in json[@"classes"]) {
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *klass = (NSDictionary *)obj;
        NSString *className = WAGRInvString(klass[@"class"]);
        if (!className.length) continue;
        Class cls = NSClassFromString(className);
        if (!cls) continue;

        NSString *role = WAGRInvString(klass[@"role"]);
        NSString *category = role.length ? role : fallbackCategory;
        NSArray *getters = [klass[@"boolGetters"] isKindOfClass:NSArray.class] ? klass[@"boolGetters"] : @[];
        for (id g in getters) {
            NSString *selector = [g isKindOfClass:NSDictionary.class] ? WAGRInvString(((NSDictionary *)g)[@"selector"]) : WAGRInvString(g);
            if (!selector.length || [selector containsString:@":"]) continue;
            if (WAGRInvBoolNoArgMethod(cls, selector, NO)) {
                WAGRInvAddEntry(entries, seen, spec, className, selector, NO, selector, category, NO,
                                WAGRInvString(klass[@"source"]), @"runtime-validated");
            }
            if (WAGRInvBoolNoArgMethod(cls, selector, YES)) {
                WAGRInvAddEntry(entries, seen, spec, className, selector, YES, selector, category, NO,
                                WAGRInvString(klass[@"source"]), @"runtime-validated");
            }
        }
    }

    return [entries sortedArrayUsingComparator:^NSComparisonResult(WAGREntry *a, WAGREntry *b) {
        NSComparisonResult r = [a.category localizedCaseInsensitiveCompare:b.category];
        if (r != NSOrderedSame) return r;
        r = [a.className localizedCaseInsensitiveCompare:b.className];
        if (r != NSOrderedSame) return r;
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
}

+ (NSString *)diagnosticText {
    NSDictionary<NSString *, NSDictionary *> *all = WAGRInvCache();
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *k in @[@"manifest.json", @"WAABProperties.json", @"WAServerProperties.json", @"WAContext.json", @"WAAura.json", @"WAMobileConfig.json", @"WAFoa.json", @"WABiz.json"]) {
        if (all[k]) [found addObject:k];
    }
    return [NSString stringWithFormat:@"runtime inventory files = %lu\n%@\npaths checked:\n%@",
            (unsigned long)found.count,
            found.count ? [found componentsJoinedByString:@"\n"] : @"(nenhum)",
            [WAGRInvCandidateDirs() componentsJoinedByString:@"\n"]];
}

@end
