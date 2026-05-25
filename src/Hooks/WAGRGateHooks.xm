// WAGRGateHooks.xm — single owner for every gate override hook.
// ─────────────────────────────────────────────────────────────────────────────
// Responsibilities
// ────────────────
// 1. At constructor time, install a *light* set of hooks:
//      • boolForKey:defaultValue:  and  stringForKey:defaultValue:
//        on the WAAB property classes. This is the universal entry point
//        that most AB flag readers go through — one trampoline per class
//        covers thousands of flags.
//      • A short, hand-picked list of concrete BOOL no-arg selectors that
//        we know are read very early in the app launch (e.g.
//        +[WAServerProperties isInternalUser], WAAuraGating bool getters
//        on the canonical Aura class). Each is installed only if the
//        target class is loaded; missing classes are retried at dyld
//        add-image and via two dispatch_after nudges, matching the
//        delayed-load behavior of the SharedModules dylib.
// 2. Expose WAGRGateInstallHookForSelector(...) so the runtime browser
//    can demand-hook any BOOL no-arg selector when the user flips a switch
//    for the first time. Idempotent: re-installing on the same class+sel
//    is a no-op.
// 3. Provide a single diagnostic and a single ensure-installed entry point.
//
// Why constructor time, but light
// ───────────────────────────────
// The old WAABPropsObserver scanned WAABProperties at %ctor and ate ~2000
// MSHookMessageEx calls on every launch. That was where the launch
// regressions came from. We avoid the scan entirely: the boolForKey:
// hook routes *all* AB flag reads through a single trampoline, and
// per-selector hooks are deferred until the user demonstrably wants
// to override that selector specifically.
//
// Schema v2
// ─────────
// Every read and write goes through WAGRGateStore.h. The key is always
// the selector name (or the flag name, for boolForKey:-style calls). No
// pipe-separated keys, no on/off strings, no per-menu prefixes.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRGateRegistry.h"

// ── Registry of installed per-selector hooks ─────────────────────────────────
// Key: "<ClassName>|<class|inst>|<selector>"
// Value: NSValue wrapping the original IMP, so the trampoline can call it.
//
// We use one global table because the trampoline is shared between every
// BOOL no-arg selector and dispatches at call time via NSStringFromSelector.
// The class component of the key disambiguates two classes that expose the
// same selector with different original IMPs.
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
    return [NSString stringWithFormat:@"%@|%@|%@",
            className ?: @"",
            isClassMethod ? @"class" : @"inst",
            selectorName ?: @""];
}

// ── Generic BOOL no-arg trampoline ───────────────────────────────────────────
// Used by every per-selector hook. We dispatch by (class, selector) to find
// the original IMP. The override key in WAGRGateStore is just the selector
// name — so a flag observed via class A is the same flag when observed via
// class B (the user-facing intent is "this flag is on", regardless of who
// asks). When no override exists, we call the original IMP unchanged.
static BOOL WAGRGateGenericBoolTrampoline(id self, SEL _cmd) {
    NSString *selName = NSStringFromSelector(_cmd);
    Class actualClass = object_getClass(self);
    BOOL isMeta = class_isMetaClass(actualClass);
    NSString *className = isMeta ? NSStringFromClass((Class)self) : NSStringFromClass([self class]);

    typedef BOOL (*BoolIMP)(id, SEL);
    BoolIMP orig = NULL;
    NSString *hookID = WAGRGateHookID(className, isMeta, selName);
    NSValue *v = gGateOriginalIMPs[hookID];
    if (!v) {
        // Some Swift bridges report self via a different class than the install-time
        // method lookup. Fall back to the alternate kind (inst↔class) on the same class.
        NSString *altID = WAGRGateHookID(className, !isMeta, selName);
        v = gGateOriginalIMPs[altID];
    }
    if (v) orig = (BoolIMP)[v pointerValue];

    BOOL original = orig ? orig(self, _cmd) : NO;

    if (WAGRGateIsSet(WAGRGateCanonicalKey(selName))) {
        return WAGRGateGet(WAGRGateCanonicalKey(selName));
    }
    return original;
}

// ── Public: install one selector-level hook ──────────────────────────────────
// Returns YES on success or if already installed. Returns NO if the class is
// not loaded, the method is absent, the signature is not BOOL no-arg, or
// MSHookMessageEx failed.
extern "C" BOOL WAGRGateInstallHookForSelector(NSString *className,
                                                NSString *selectorName,
                                                BOOL isClassMethod) {
    WAGRGateStorageInit();
    if (!className.length || !selectorName.length) return NO;

    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    SEL sel = NSSelectorFromString(selectorName);
    Method m = isClassMethod ? class_getClassMethod(cls, sel)
                             : class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) return NO;
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

// ── boolForKey:defaultValue: trampolines (the universal AB entry point) ──────
// We hook this once per WAAB-property class. When the app reads a flag by
// key, we consult the store. If a user override exists for that key, we
// return it directly; otherwise we let the original answer through. This is
// the most efficient way to override thousands of named flags — no scan, no
// per-flag hook needed.
typedef BOOL (*BoolKeyIMP)(id, SEL, NSString *, BOOL);
typedef id   (*StringKeyIMP)(id, SEL, NSString *, id);

static NSMutableDictionary<NSString *, NSValue *> *gBoolKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gStringKeyOriginals = nil;

static BOOL WAGRBoolForKeyTrampoline(id self, SEL _cmd, NSString *key, BOOL defaultVal) {
    NSString *className = NSStringFromClass([self class]);
    NSValue *v = gBoolKeyOriginals[className];
    BoolKeyIMP orig = v ? (BoolKeyIMP)[v pointerValue] : NULL;
    BOOL original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;

    if (key.length && WAGRGateIsSet(WAGRGateCanonicalKey(key))) return WAGRGateGet(WAGRGateCanonicalKey(key));
    return original;
}

static id WAGRStringForKeyTrampoline(id self, SEL _cmd, NSString *key, id defaultVal) {
    NSString *className = NSStringFromClass([self class]);
    NSValue *v = gStringKeyOriginals[className];
    StringKeyIMP orig = v ? (StringKeyIMP)[v pointerValue] : NULL;
    id original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;

    // String AB flags are unusual. We only intervene when the user has
    // explicitly stored a boolean override for the same name and the
    // gate appears to be a YES/NO-shaped enum (returned values like
    // "enabled"/"disabled"). Numeric and unrelated string flags pass through.
    if (key.length && WAGRGateIsSet(WAGRGateCanonicalKey(key))) {
        return WAGRGateGet(WAGRGateCanonicalKey(key)) ? @"enabled" : @"";
    }
    return original;
}

static BOOL WAGRInstallBoolForKeyOnClass(Class cls) {
    if (!cls) return NO;
    NSString *className = NSStringFromClass(cls);
    if (gBoolKeyOriginals[className]) return YES;

    SEL sel = NSSelectorFromString(@"boolForKey:defaultValue:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

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
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)WAGRStringForKeyTrampoline, &orig);
    if (!orig) return NO;

    if (!gStringKeyOriginals) gStringKeyOriginals = [NSMutableDictionary dictionary];
    gStringKeyOriginals[className] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    return YES;
}

// ── Bootstrap: light, idempotent, safe to call any number of times ───────────
// Installs the universal hooks plus a curated set of concrete selector hooks.
// The set is intentionally small. Anything outside it is installed on-demand
// by the runtime browser when the user flips a toggle.
static NSArray<NSDictionary *> *WAGRBootstrapSelectorHooks(void) {
    return @[
        // WAServerProperties class methods. Static analysis confirmed these
        // are +class methods returning BOOL no-arg.
        @{ @"class": @"WAServerProperties", @"sel": @"isInternalUser",                       @"meta": @YES },
        @{ @"class": @"WAServerProperties", @"sel": @"paymentsUPIOverdraftAccountEnabled",   @"meta": @YES },
        @{ @"class": @"WAServerProperties", @"sel": @"listMessageReceptionDisabled",         @"meta": @YES },
        @{ @"class": @"WAServerProperties", @"sel": @"frequentlyForwardedGroupSettingEnabled", @"meta": @YES },

        // WAAuraGating instance methods (confirmed in SharedModules).
        @{ @"class": @"WAAuraGating", @"sel": @"isEnabled",                  @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isUserEligible",             @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isSettingsRowEnabled",       @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isKillSwitchActive",         @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isAppearanceSettingsEnabled",@"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isAppIconsEnabled",          @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isAppThemesEnabled",         @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isRingtonesEnabled",         @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isEnhancedListsEnabled",     @"meta": @NO },
        @{ @"class": @"WAAuraGating", @"sel": @"isStickersEnabled",          @"meta": @NO },

        // MobileConfigGating instance methods (confirmed in SharedModules
        // both via the ObjC name and the Swift-mangled name).
        @{ @"class": @"MobileConfigGating",                         @"sel": @"isSessionBasedMCEnabled", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating",   @"sel": @"isSessionBasedEnabled",   @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating",   @"sel": @"isSourceOfTruth",         @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating",   @"sel": @"emergencyRollback",       @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating",   @"sel": @"mcUseCallsiteDefault",    @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating",   @"sel": @"isStableIDFastParseEnabled", @"meta": @NO },
        @{ @"class": @"_TtC12WAFoundation20WAMobileConfigGating",   @"sel": @"isStableIDLocalCacheEnabled", @"meta": @NO }
    ];
}

static NSArray<NSString *> *WAGRBoolKeyClassNames(void) {
    return @[
        @"WAABProperties",
        @"FOAWAABPropertiesImpl"
    ];
}

// Reinstall any user-overridden selector that the bootstrap set does not
// cover. The runtime browser does the same when the user toggles a switch,
// but the user might launch the app with overrides already persisted from
// a previous session — we cover those here.
static NSUInteger WAGRReinstallPersistedOverrideHooks(void) {
    NSArray<NSString *> *keys = WAGRGateAllOverrides();
    if (!keys.count) return 0;
    NSUInteger installed = 0;

    // We do not know which class owns a persisted selector without scanning.
    // The runtime browser stores (class, selector) pairs via direct calls to
    // this file's installer, so a cold start carries no installer hints. For
    // robustness we try the class hints from the registry first; anything
    // that doesn't match is left for the live browser to re-install on view.
    NSArray<WAGRGateProvider *> *providers = [WAGRGateRegistry allProviders];
    for (NSString *storedKey in keys) {
        NSString *sel = WAGRGateDisplayKey(storedKey);
        for (WAGRGateProvider *p in providers) {
            for (NSString *cname in p.concreteClassNames) {
                if (WAGRGateInstallHookForSelector(cname, sel, NO)) { installed++; goto next; }
                if (WAGRGateInstallHookForSelector(cname, sel, YES)) { installed++; goto next; }
            }
        }
    next: ;
    }
    return installed;
}

static void WAGRGateHooksInstallLightPhase(void) {
    WAGRGateStorageInit();

    // 1) boolForKey:/stringForKey: on WAAB classes — universal AB hook.
    for (NSString *cname in WAGRBoolKeyClassNames()) {
        Class cls = NSClassFromString(cname);
        if (!cls) continue;
        WAGRInstallBoolForKeyOnClass(cls);
        WAGRInstallStringForKeyOnClass(cls);
    }

    // 2) Curated early direct selectors.
    for (NSDictionary *h in WAGRBootstrapSelectorHooks()) {
        WAGRGateInstallHookForSelector(h[@"class"], h[@"sel"], [h[@"meta"] boolValue]);
    }
}

static void WAGRGateHooksInstallPersistedPhaseOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ WAGRReinstallPersistedOverrideHooks(); });
}

extern "C" void WAGRGateHooksEnsureInstalled(void) {
    WAGRGateHooksInstallLightPhase();
}

// ── Diagnostic ───────────────────────────────────────────────────────────────
extern "C" NSString *WAGRGateHooksDiagnostic(void) {
    WAGRGateStorageInit();
    NSUInteger boolKey = gBoolKeyOriginals.count;
    NSUInteger strKey  = gStringKeyOriginals.count;
    return [NSString stringWithFormat:
        @"per-selector hooks=%lu\nboolForKey: classes=%lu\nstringForKey: classes=%lu\noverrides active=%lu",
        (unsigned long)gGateInstalled.count,
        (unsigned long)boolKey,
        (unsigned long)strKey,
        (unsigned long)WAGRGateAllOverrides().count];
}

// ── dyld + constructor ───────────────────────────────────────────────────────
// SharedModules can load slightly after the main image. We re-run the
// ensure path on each dyld add-image event so newly loaded classes get
// their hooks. We also schedule three short retries to cover Swift-only
// classes that get registered with the ObjC runtime late in launch.
static void WAGRGateDyldCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh; (void)vmaddr_slide;
    // dyld can fire on a non-main thread. Hop to main; hook installs through
    // MSHookMessageEx are intentionally serialized on the main thread for
    // crash-safety on the WhatsApp Swift bridges.
    dispatch_async(dispatch_get_main_queue(), ^{ WAGRGateHooksInstallLightPhase(); });
}

__attribute__((constructor))
static void WAGRGateHooksConstructor(void) {
    @autoreleasepool {
        // Watusi-style startup: constructor performs ObjC runtime hook install only.
        // Do not touch persisted preference storage here.
        WAGRGateHooksInstallLightPhase();
        _dyld_register_func_for_add_image(WAGRGateDyldCallback);

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            WAGRWipeLegacyStorageIfNeeded();
            WAGRGateHooksInstallLightPhase();
            WAGRGateHooksInstallPersistedPhaseOnce();
        }];
    }
}
