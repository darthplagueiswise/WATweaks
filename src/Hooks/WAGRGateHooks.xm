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

static void WAGRGateStorageInit(void) {
    dispatch_once(&gGateOnce, ^{
        gGateOriginalIMPs = [NSMutableDictionary dictionaryWithCapacity:256];
        gGateInstalled = [NSMutableSet setWithCapacity:128];
        gBoolKeyOriginals = [NSMutableDictionary dictionary];
        gStringKeyOriginals = [NSMutableDictionary dictionary];
        gIntegerKeyOriginals = [NSMutableDictionary dictionary];
        gDoubleKeyOriginals = [NSMutableDictionary dictionary];
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
    if (v) orig = (BoolIMP)[v pointerValue];
    BOOL original = orig ? orig(self, _cmd) : NO;
    return WAGRGateValueForSelector(selName, original);
}

extern "C" BOOL WAGRGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod) {
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
    if ([gGateInstalled containsObject:hookID]) return YES;
    Class target = isClassMethod ? object_getClass(cls) : cls;
    IMP orig = NULL;
    MSHookMessageEx(target, sel, (IMP)WAGRGateGenericBoolTrampoline, &orig);
    if (!orig) return NO;
    gGateOriginalIMPs[hookID] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    [gGateInstalled addObject:hookID];
    return YES;
}

typedef BOOL      (*BoolKeyIMP)(id, SEL, NSString *, BOOL);
typedef id        (*StringKeyIMP)(id, SEL, NSString *, id);
typedef long long (*IntegerKeyIMP)(id, SEL, NSString *, long long);
typedef double    (*DoubleKeyIMP)(id, SEL, NSString *, double);

static BOOL WAGRBoolForKeyTrampoline(id self, SEL _cmd, NSString *key, BOOL defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    BoolKeyIMP orig = gBoolKeyOriginals[className] ? (BoolKeyIMP)[gBoolKeyOriginals[className] pointerValue] : NULL;
    BOOL original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key);
    return original;
}
static id WAGRStringForKeyTrampoline(id self, SEL _cmd, NSString *key, id defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    StringKeyIMP orig = gStringKeyOriginals[className] ? (StringKeyIMP)[gStringKeyOriginals[className] pointerValue] : NULL;
    id original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key) ? @"1" : @"";
    return original;
}
static long long WAGRIntegerForKeyTrampoline(id self, SEL _cmd, NSString *key, long long defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    IntegerKeyIMP orig = gIntegerKeyOriginals[className] ? (IntegerKeyIMP)[gIntegerKeyOriginals[className] pointerValue] : NULL;
    long long original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key) ? 1LL : 0LL;
    return original;
}
static double WAGRDoubleForKeyTrampoline(id self, SEL _cmd, NSString *key, double defaultVal) {
    WAGRGateStorageInit();
    NSString *className = NSStringFromClass([self class]);
    DoubleKeyIMP orig = gDoubleKeyOriginals[className] ? (DoubleKeyIMP)[gDoubleKeyOriginals[className] pointerValue] : NULL;
    double original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
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

static void WAGRGateHooksInstallLightPhase(void) {
    WAGRGateStorageInit();
    for (NSString *cname in @[ @"FOAWAABPropertiesImpl", @"WAABProperties" ]) {
        Class cls = NSClassFromString(cname) ?: objc_getClass(cname.UTF8String);
        if (cls) WAGRInstallWAABKeyHooksOnClass(cls);
    }
    for (NSDictionary *h in WAGRBootstrapSelectorHooks()) {
        WAGRGateInstallHookForSelector(h[@"class"], h[@"sel"], [h[@"meta"] boolValue]);
    }
}

static void WAGRGateHooksInstallPersistedPhaseOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *keys = WAGRGateAllOverrides();
        if (!keys.count) return;
        NSArray<WAGRGateProvider *> *providers = [WAGRGateRegistry allProviders];
        for (NSString *storedKey in keys) {
            NSString *sel = WAGRGateDisplayKey(storedKey);
            for (WAGRGateProvider *p in providers) {
                BOOL done = NO;
                for (NSString *cname in p.concreteClassNames) {
                    if (WAGRGateInstallHookForSelector(cname, sel, NO) || WAGRGateInstallHookForSelector(cname, sel, YES)) { done = YES; break; }
                }
                if (done) break;
            }
        }
    });
}

extern "C" void WAGRGateHooksEnsureInstalled(void) {
    WAGRGateHooksInstallLightPhase();
    WAGRGateHooksInstallPersistedPhaseOnce();
}

extern "C" NSString *WAGRGateHooksDiagnostic(void) {
    WAGRGateStorageInit();
    return [NSString stringWithFormat:@"per-selector hooks=%lu\nboolForKey classes=%lu\nstringForKey classes=%lu\nintegerForKey classes=%lu\ndoubleForKey classes=%lu\noverrides active=%lu",
        (unsigned long)gGateInstalled.count,
        (unsigned long)gBoolKeyOriginals.count,
        (unsigned long)gStringKeyOriginals.count,
        (unsigned long)gIntegerKeyOriginals.count,
        (unsigned long)gDoubleKeyOriginals.count,
        (unsigned long)WAGRGateAllOverrides().count];
}

__attribute__((constructor))
static void WAGRGateHooksConstructor(void) {
    @autoreleasepool {
        WAGRGateHooksInstallLightPhase();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRGateHooksInstallLightPhase(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRGateHooksInstallLightPhase(); });
    }
}
