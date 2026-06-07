// WAGRGateHooks.xm — single owner for every gate override hook.
// SDK 26.2 refresh: WAAB hot path covers bool/string/integer/doubleForKey:defaultValue:.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRGateRegistry.h"

static NSMutableDictionary<NSString *, NSValue *> *gGateOriginalIMPs = nil;
static NSMutableSet<NSString *> *gGateInstalled = nil;
static dispatch_once_t gGateOnce;

static NSMutableDictionary<NSString *, NSValue *> *gBoolKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gStringKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gIntegerKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gDoubleKeyOriginals = nil;
static NSMutableSet<NSString *> *gWAABObservedKeys = nil;
static dispatch_queue_t gWAABObservedQueue = nil;

static void WAGRGateStorageInit(void) {
    dispatch_once(&gGateOnce, ^{
        gGateOriginalIMPs = [NSMutableDictionary dictionaryWithCapacity:256];
        gGateInstalled = [NSMutableSet setWithCapacity:128];
        gBoolKeyOriginals = [NSMutableDictionary dictionary];
        gStringKeyOriginals = [NSMutableDictionary dictionary];
        gIntegerKeyOriginals = [NSMutableDictionary dictionary];
        gDoubleKeyOriginals = [NSMutableDictionary dictionary];
        gWAABObservedKeys = [NSMutableSet setWithCapacity:1024];
        gWAABObservedQueue = dispatch_queue_create("com.watweaks.waab.observed", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *WAGRGateHookID(NSString *className, BOOL isClassMethod, NSString *selectorName) {
    return [NSString stringWithFormat:@"%@|%@|%@", className ?: @"", isClassMethod ? @"class" : @"inst", selectorName ?: @""];
}

static BOOL WAGRGateValueForSelector(NSString *selectorName, BOOL original) {
    NSString *ck = WAGRGateCanonicalKey(selectorName);
    if (WAGRGateIsSet(ck)) return WAGRGateGet(ck);
    return original;
}

static BOOL WAGRGateGenericBoolTrampoline(id self, SEL _cmd) {
    NSString *selName = NSStringFromSelector(_cmd);
    Class actualClass = object_getClass(self);
    BOOL isMeta = class_isMetaClass(actualClass);
    NSString *className = isMeta ? NSStringFromClass((Class)self) : NSStringFromClass([self class]);
    typedef BOOL (*BoolIMP)(id, SEL);
    BoolIMP orig = NULL;
    NSString *hookID = WAGRGateHookID(className, isMeta, selName);
    NSValue *v = gGateOriginalIMPs[hookID] ?: gGateOriginalIMPs[WAGRGateHookID(className, !isMeta, selName)];
    if (v) orig = reinterpret_cast<BoolIMP>([v pointerValue]);
    BOOL original = orig ? orig(self, _cmd) : NO;
    return WAGRGateValueForSelector(selName, original);
}

static BOOL WAGRGateInstallHookForSelectorInternal(NSString *className, NSString *selectorName, BOOL isClassMethod, BOOL remember) {
    WAGRGateStorageInit();
    if (!className.length || !selectorName.length) return NO;
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'B' && ret[0] != 'c') return NO;
    NSString *hookID = WAGRGateHookID(className, isClassMethod, selectorName);
    if ([gGateInstalled containsObject:hookID]) {
        if (remember) WAGRGateRememberHook(className, selectorName, isClassMethod);
        return YES;
    }
    Class target = isClassMethod ? object_getClass(cls) : cls;
    IMP orig = NULL;
    MSHookMessageEx(target, sel, (IMP)WAGRGateGenericBoolTrampoline, &orig);
    if (!orig) return NO;
    gGateOriginalIMPs[hookID] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    [gGateInstalled addObject:hookID];
    if (remember) WAGRGateRememberHook(className, selectorName, isClassMethod);
    return YES;
}

extern "C" BOOL WAGRGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod) {
    return WAGRGateInstallHookForSelectorInternal(className, selectorName, isClassMethod, YES);
}


static void WAGRWAABRememberObservedKey(NSString *key) {
    if (!key.length) return;
    WAGRGateStorageInit();
    NSString *copy = [key copy];
    dispatch_async(gWAABObservedQueue, ^{ [gWAABObservedKeys addObject:copy]; });
}

extern "C" NSArray<NSString *> *WAGRWAABObservedKeys(void) {
    WAGRGateStorageInit();
    __block NSArray<NSString *> *snapshot = nil;
    dispatch_sync(gWAABObservedQueue, ^{ snapshot = [[gWAABObservedKeys allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]; });
    NSMutableOrderedSet<NSString *> *merged = [NSMutableOrderedSet orderedSetWithArray:snapshot ?: @[]];
    for (NSString *stored in WAGRGateAllOverrides()) {
        NSString *display = WAGRGateDisplayKey(stored);
        if (display.length) [merged addObject:display];
    }
    return merged.array;
}


static NSString *WAGRWAABFirstReadableToken(NSArray *tokens) {
    for (id obj in tokens) {
        if (![obj isKindOfClass:NSString.class]) continue;
        NSString *t = (NSString *)obj;
        if (t.length < 3) continue;
        if ([t rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) continue;
        if ([t hasPrefix:@"_"] || [t hasPrefix:@"{"] || [t hasPrefix:@"["]) continue;
        return t;
    }
    return nil;
}

static void WAGRWAABIngestNameMapJSON(id json, NSMutableDictionary<NSString *, NSString *> *map) {
    if (!json || !map) return;
    if ([json isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)json;
        id nested = d[@"id_name_mapping"] ?: d[@"idNameMapping"] ?: d[@"mapping"] ?: d[@"params"] ?: d[@"features"];
        if (nested && nested != json) WAGRWAABIngestNameMapJSON(nested, map);
        [d enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NSString *ks = [k description]; NSString *vs = [v description];
            BOOL kNum = [ks rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound;
            BOOL vNum = [vs rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound;
            if (kNum && vs.length && ![vs isEqualToString:ks]) map[ks] = vs;
            else if (vNum && ks.length && ![ks isEqualToString:vs]) map[vs] = ks;
        }];
    } else if ([json isKindOfClass:NSArray.class]) {
        for (id obj in (NSArray *)json) {
            if ([obj isKindOfClass:NSDictionary.class]) {
                NSDictionary *d = (NSDictionary *)obj;
                NSString *num = nil;
                NSString *name = nil;
                for (NSString *k in @[@"id", @"param_id", @"paramId", @"key", @"abid", @"ab_id"]) {
                    id v = d[k];
                    if (v && [[v description] rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound) { num = [v description]; break; }
                }
                for (NSString *k in @[@"name", @"feature", @"feature_name", @"featureName", @"param_name", @"paramName", @"display_name", @"displayName"]) {
                    id v = d[k];
                    if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) { name = (NSString *)v; break; }
                }
                if (num.length && name.length) map[num] = name;
                else WAGRWAABIngestNameMapJSON(d, map);
            }
        }
    }
}

static void WAGRWAABLoadNameMapFile(NSString *path, NSMutableDictionary<NSString *, NSString *> *map) {
    if (!path.length || !map) return;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 12*1024*1024) return;
    NSString *last = path.lastPathComponent.lowercaseString ?: @"";
    if ([last hasSuffix:@".json"]) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        WAGRWAABIngestNameMapJSON(json, map);
        return;
    }
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!txt.length) return;
    [txt enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if (line.length < 3 || [line hasPrefix:@"#"]) return;
        NSArray *parts = [line componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t,;:=|\""]];
        NSMutableArray *tokens = [NSMutableArray array];
        for (NSString *p in parts) if (p.length) [tokens addObject:p];
        NSString *num = nil;
        for (NSString *t in tokens) if ([t rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound) { num = t; break; }
        if (!num.length) return;
        NSString *name = WAGRWAABFirstReadableToken(tokens);
        if (name.length && ![name isEqualToString:num]) map[num] = name;
    }];
}

static NSDictionary<NSString *, NSString *> *WAGRWAABLoadRuntimeNameMap(void) {
    static NSDictionary *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *candidateFiles = [NSMutableArray array];
        NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];

        NSArray<NSBundle *> *bundles = [[NSBundle allBundles] arrayByAddingObjectsFromArray:[NSBundle allFrameworks]];
        for (NSBundle *b in bundles) {
            NSString *p = [b pathForResource:@"id_name_mapping" ofType:@"json"];
            if (p.length) [candidateFiles addObject:p];
            p = [b pathForResource:@"waab_id_name_mapping" ofType:@"json"];
            if (p.length) [candidateFiles addObject:p];
            if (b.resourcePath.length) [roots addObject:b.resourcePath];
            if (b.bundlePath.length) [roots addObject:b.bundlePath];
        }
        for (NSString *clsName in @[@"WAABProperties", @"FOAWAABPropertiesImpl", @"WAABPropertiesPreChatd"]) {
            Class cls = NSClassFromString(clsName) ?: objc_getClass(clsName.UTF8String);
            if (!cls) continue;
            NSBundle *b = [NSBundle bundleForClass:cls];
            if (b.resourcePath.length) [roots addObject:b.resourcePath];
            if (b.bundlePath.length) [roots addObject:b.bundlePath];
        }
        NSArray *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        if (lib.firstObject) [roots addObject:lib.firstObject];
        [roots addObject:@"/Library/Application Support/WATweaks/runtime"];
        [roots addObject:@"/var/jb/Library/Application Support/WATweaks/runtime"];
        [roots addObject:@"/var/mobile/Library/Application Support/WATweaks/runtime"];

        for (NSString *path in candidateFiles) WAGRWAABLoadNameMapFile(path, map);

        NSFileManager *fm = NSFileManager.defaultManager;
        NSUInteger scanned = 0;
        for (NSString *root in roots) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
            NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
            NSString *rel = nil;
            while ((rel = [e nextObject])) {
                if (++scanned > 16000) break;
                NSString *last = rel.lastPathComponent.lowercaseString ?: @"";
                if (!([last containsString:@"id_name_mapping"] || [last containsString:@"waab_id_name_mapping"] || [last containsString:@"params_map"] || [last containsString:@"params_names"])) continue;
                WAGRWAABLoadNameMapFile([root stringByAppendingPathComponent:rel], map);
            }
        }
        cached = [map copy];
    });
    return cached ?: @{};
}

extern "C" NSString *WAGRWAABDisplayNameForKey(NSString *key) {
    if (!key.length) return @"";
    NSDictionary *map = WAGRWAABLoadRuntimeNameMap();
    NSString *mapped = map[key];
    if (mapped.length) return mapped;
    if ([key rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound) return [NSString stringWithFormat:@"ABProperty %@", key];
    return key;
}

typedef BOOL      (*BoolKeyIMP)(id, SEL, NSString *, BOOL);
typedef id        (*StringKeyIMP)(id, SEL, NSString *, id);
typedef long long (*IntegerKeyIMP)(id, SEL, NSString *, long long);
typedef double    (*DoubleKeyIMP)(id, SEL, NSString *, double);

static BOOL WAGRBoolForKeyTrampoline(id self, SEL _cmd, NSString *key, BOOL defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    BoolKeyIMP orig = gBoolKeyOriginals[className] ? reinterpret_cast<BoolKeyIMP>([gBoolKeyOriginals[className] pointerValue]) : NULL;
    BOOL original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    WAGRWAABRememberObservedKey(key);
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key);
    return original;
}
static id WAGRStringForKeyTrampoline(id self, SEL _cmd, NSString *key, id defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    StringKeyIMP orig = gStringKeyOriginals[className] ? reinterpret_cast<StringKeyIMP>([gStringKeyOriginals[className] pointerValue]) : NULL;
    id original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    WAGRWAABRememberObservedKey(key);
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key) ? @"1" : @"";
    return original;
}
static long long WAGRIntegerForKeyTrampoline(id self, SEL _cmd, NSString *key, long long defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    IntegerKeyIMP orig = gIntegerKeyOriginals[className] ? reinterpret_cast<IntegerKeyIMP>([gIntegerKeyOriginals[className] pointerValue]) : NULL;
    long long original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    WAGRWAABRememberObservedKey(key);
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key) ? 1LL : 0LL;
    return original;
}
static double WAGRDoubleForKeyTrampoline(id self, SEL _cmd, NSString *key, double defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    DoubleKeyIMP orig = gDoubleKeyOriginals[className] ? reinterpret_cast<DoubleKeyIMP>([gDoubleKeyOriginals[className] pointerValue]) : NULL;
    double original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    WAGRWAABRememberObservedKey(key);
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key) ? 1.0 : 0.0;
    return original;
}

static BOOL WAGRInstallKeyHookOnClass(Class cls, NSString *selName, IMP replacement, NSMutableDictionary<NSString *, NSValue *> *store) {
    if (!cls || !selName.length || !replacement || !store) return NO;
    NSString *className = NSStringFromClass(cls);
    if (store[className]) return YES;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, replacement, &orig);
    if (!orig) return NO;
    store[className] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    return YES;
}

static void WAGRInstallWAABKeyHooksOnClass(Class cls) {
    WAGRGateStorageInit();
    if (!cls) return;
    WAGRInstallKeyHookOnClass(cls, @"boolForKey:defaultValue:",    (IMP)WAGRBoolForKeyTrampoline,    gBoolKeyOriginals);
    WAGRInstallKeyHookOnClass(cls, @"stringForKey:defaultValue:",  (IMP)WAGRStringForKeyTrampoline,  gStringKeyOriginals);
    WAGRInstallKeyHookOnClass(cls, @"integerForKey:defaultValue:", (IMP)WAGRIntegerForKeyTrampoline, gIntegerKeyOriginals);
    WAGRInstallKeyHookOnClass(cls, @"doubleForKey:defaultValue:",  (IMP)WAGRDoubleForKeyTrampoline,  gDoubleKeyOriginals);
}

static NSArray<NSDictionary *> *WAGRBootstrapSelectorHooks(void) {
    return @[
        @{ @"class": @"WAServerProperties", @"sel": @"isInternalUser", @"meta": @YES },
        @{ @"class": @"WAServerProperties", @"sel": @"paymentsUPIOverdraftAccountEnabled", @"meta": @YES },
        @{ @"class": @"WAServerProperties", @"sel": @"listMessageReceptionDisabled", @"meta": @YES },
        @{ @"class": @"WAServerProperties", @"sel": @"frequentlyForwardedGroupSettingEnabled", @"meta": @YES },
        @{ @"class": @"WAAuraGating", @"sel": @"isEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isUserEligible", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isSettingsRowEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isKillSwitchActive", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isAppearanceSettingsEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isAppIconsEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isAppThemesEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isRingtonesEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isEnhancedListsEnabled", @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isStickersEnabled", @"meta": @NO },
        @{ @"class": @"WDSLiquidGlass", @"sel": @"isM0Enabled", @"meta": @YES },
        @{ @"class": @"WDSLiquidGlass", @"sel": @"isM1Enabled", @"meta": @YES },
        @{ @"class": @"WDSLiquidGlass", @"sel": @"isM1_5Enabled", @"meta": @YES },
        @{ @"class": @"WDSLiquidGlass", @"sel": @"isChatTopBarM2Enabled", @"meta": @YES },
        @{ @"class": @"WDSLiquidGlass", @"sel": @"isUnifyNavigationBarEnabled", @"meta": @YES },
        @{ @"class": @"WDSLiquidGlass", @"sel": @"shouldUseNativeSwipeActions", @"meta": @YES },
        @{ @"class": @"MobileConfigGating", @"sel": @"isSessionBasedMCEnabled", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating", @"sel": @"isSessionBasedEnabled", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating", @"sel": @"isSourceOfTruth", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating", @"sel": @"emergencyRollback", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating", @"sel": @"mcUseCallsiteDefault", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating", @"sel": @"isStableIDFastParseEnabled", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating", @"sel": @"isStableIDLocalCacheEnabled", @"meta": @NO }
    ];
}

static BOOL WAGRClassLooksLikeWAABProvider(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls) ?: @"";
    if (!([name containsString:@"ABProperties"] || [name containsString:@"MobileConfig"] || [name containsString:@"FOAWAAB"])) return NO;
    return class_getInstanceMethod(cls, NSSelectorFromString(@"boolForKey:defaultValue:")) ||
           class_getInstanceMethod(cls, NSSelectorFromString(@"integerForKey:defaultValue:")) ||
           class_getInstanceMethod(cls, NSSelectorFromString(@"doubleForKey:defaultValue:")) ||
           class_getInstanceMethod(cls, NSSelectorFromString(@"stringForKey:defaultValue:"));
}

static void WAGRInstallWAABKeyHooksDirectedScan(void) {
    NSArray *direct = @[ @"FOAWAABPropertiesImpl", @"WAFoundation.FOAWAABPropertiesImpl", @"WAABProperties", @"WAABPropertiesPreChatd" ];
    for (NSString *cname in direct) {
        Class cls = NSClassFromString(cname) ?: objc_getClass(cname.UTF8String);
        if (cls) WAGRInstallWAABKeyHooksOnClass(cls);
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (WAGRClassLooksLikeWAABProvider(cls)) WAGRInstallWAABKeyHooksOnClass(cls);
    }
    free(classes);
}

static void WAGRGateHooksInstallLightPhase(void) {
    WAGRGateStorageInit();
    WAGRInstallWAABKeyHooksDirectedScan();
    for (NSDictionary *h in WAGRBootstrapSelectorHooks()) {
        WAGRGateInstallHookForSelectorInternal(h[@"class"], h[@"sel"], [h[@"meta"] boolValue], NO);
    }
}

static void WAGRGateHooksInstallPersistedPhase(void) {
    for (NSDictionary *d in WAGRGatePersistedHookSpecs()) {
        NSString *c = d[@"class"];
        NSString *s = d[@"selector"];
        BOOL meta = [d[@"meta"] boolValue];
        WAGRGateInstallHookForSelectorInternal(c, s, meta, NO);
    }

    NSArray<NSString *> *keys = WAGRGateAllOverrides();
    if (!keys.count) return;
    NSArray<WAGRGateProvider *> *providers = [WAGRGateRegistry allProviders];
    for (NSString *storedKey in keys) {
        NSString *sel = WAGRGateDisplayKey(storedKey);
        for (WAGRGateProvider *p in providers) {
            BOOL done = NO;
            for (NSString *cname in p.concreteClassNames) {
                if (WAGRGateInstallHookForSelectorInternal(cname, sel, NO, NO) ||
                    WAGRGateInstallHookForSelectorInternal(cname, sel, YES, NO)) { done = YES; break; }
            }
            if (done) break;
        }
    }
}

extern "C" void WAGRGateHooksEnsureInstalled(void) {
    WAGRGateHooksInstallLightPhase();
    WAGRGateHooksInstallPersistedPhase();
}

extern "C" NSString *WAGRGateHooksDiagnostic(void) {
    WAGRGateStorageInit();
    return [NSString stringWithFormat:@"per-selector hooks=%lu\npersisted hook specs=%lu\nboolForKey classes=%lu\nstringForKey classes=%lu\nintegerForKey classes=%lu\ndoubleForKey classes=%lu\nobserved WAAB keys=%lu\nname map entries=%lu\noverrides active=%lu",
        (unsigned long)gGateInstalled.count,
        (unsigned long)WAGRGatePersistedHookSpecs().count,
        (unsigned long)gBoolKeyOriginals.count,
        (unsigned long)gStringKeyOriginals.count,
        (unsigned long)gIntegerKeyOriginals.count,
        (unsigned long)gDoubleKeyOriginals.count,
        (unsigned long)WAGRWAABObservedKeys().count,
        (unsigned long)WAGRWAABLoadRuntimeNameMap().count,
        (unsigned long)WAGRGateAllOverrides().count];
}

__attribute__((constructor))
static void WAGRGateHooksConstructor(void) {
    @autoreleasepool {
        WAGRGateHooksInstallLightPhase();
        WAGRGateHooksInstallPersistedPhase();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRGateHooksInstallLightPhase(); WAGRGateHooksInstallPersistedPhase(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRGateHooksInstallLightPhase(); WAGRGateHooksInstallPersistedPhase(); });
    }
}
