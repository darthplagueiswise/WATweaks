// WAGRGateHooks.xm — single owner for every gate override hook.
// Constructor hot path follows Watusi timing: fixed synchronous hook install only.

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

static void WAGRGateStorageInit(void) {
    dispatch_once(&gGateOnce, ^{
        gGateOriginalIMPs = [NSMutableDictionary dictionaryWithCapacity:128];
        gGateInstalled = [NSMutableSet setWithCapacity:64];
    });
}

static NSString *WAGRGateHookID(NSString *className, BOOL isClassMethod, NSString *selectorName) {
    return [NSString stringWithFormat:@"%@|%@|%@", className ?: @"", isClassMethod ? @"class" : @"inst", selectorName ?: @""];
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
    NSString *ck = WAGRGateCanonicalKey(selName);
    if (WAGRGateIsSet(ck)) return WAGRGateGet(ck);
    return original;
}

extern "C" BOOL WAGRGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod) {
    WAGRGateStorageInit();
    if (!className.length || !selectorName.length) return NO;

    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    SEL sel = NSSelectorFromString(selectorName);
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
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

typedef BOOL (*BoolKeyIMP)(id, SEL, NSString *, BOOL);
typedef id   (*StringKeyIMP)(id, SEL, NSString *, id);

static NSMutableDictionary<NSString *, NSValue *> *gBoolKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gStringKeyOriginals = nil;

static BOOL WAGRBoolForKeyTrampoline(id self, SEL _cmd, NSString *key, BOOL defaultVal) {
    NSString *className = NSStringFromClass([self class]);
    BoolKeyIMP orig = gBoolKeyOriginals[className] ? (BoolKeyIMP)[gBoolKeyOriginals[className] pointerValue] : NULL;
    BOOL original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key);
    return original;
}

static id WAGRStringForKeyTrampoline(id self, SEL _cmd, NSString *key, id defaultVal) {
    NSString *className = NSStringFromClass([self class]);
    StringKeyIMP orig = gStringKeyOriginals[className] ? (StringKeyIMP)[gStringKeyOriginals[className] pointerValue] : NULL;
    id original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (key.length && WAGRGateIsSet(key)) return WAGRGateGet(key) ? @"enabled" : @"";
    return original;
}

static BOOL WAGRInstallBoolForKeyOnClass(Class cls) {
    if (!cls) return NO;
    NSString *className = NSStringFromClass(cls);
    if (gBoolKeyOriginals[className]) return YES;
    SEL sel = NSSelectorFromString(@"boolForKey:defaultValue:");
    if (!class_getInstanceMethod(cls, sel)) return NO;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)WAGRBoolForKeyTrampoline, &orig);
    if (!orig) return NO;
    if (!gBoolKeyOriginals) gBoolKeyOriginals = [NSMutableDictionary dictionary];
    gBoolKeyOriginals[className] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    return YES;
}

static BOOL WAGRInstallStringForKeyOnClass(Class cls) {
    if (!cls) return NO;
    NSString *className = NSStringFromClass(cls);
    if (gStringKeyOriginals[className]) return YES;
    SEL sel = NSSelectorFromString(@"stringForKey:defaultValue:");
    if (!class_getInstanceMethod(cls, sel)) return NO;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)WAGRStringForKeyTrampoline, &orig);
    if (!orig) return NO;
    if (!gStringKeyOriginals) gStringKeyOriginals = [NSMutableDictionary dictionary];
    gStringKeyOriginals[className] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    return YES;
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
    for (NSString *cname in @[ @"WAABProperties", @"FOAWAABPropertiesImpl" ]) {
        Class cls = NSClassFromString(cname);
        if (!cls) continue;
        WAGRInstallBoolForKeyOnClass(cls);
        WAGRInstallStringForKeyOnClass(cls);
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
    return [NSString stringWithFormat:@"per-selector hooks=%lu\nboolForKey: classes=%lu\nstringForKey: classes=%lu\noverrides active=%lu",
        (unsigned long)gGateInstalled.count,
        (unsigned long)gBoolKeyOriginals.count,
        (unsigned long)gStringKeyOriginals.count,
        (unsigned long)WAGRGateAllOverrides().count];
}

__attribute__((constructor))
static void WAGRGateHooksConstructor(void) {
    @autoreleasepool {
        WAGRGateHooksInstallLightPhase();
    }
}
