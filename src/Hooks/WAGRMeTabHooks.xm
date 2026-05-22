// WAGRMeTabHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Hooks for the new "Me Tab" / Contacts Hub / About Evolve / Waffle features
// that ship in 26.x but are gated off by default.
//
// Why this file exists (separate from WAAuraHooks)
// ─────────────────────────────────────────────────
// These gates are *not* part of the Aura / subscription decision graph.
// They are independent feature flags that decide:
//   • whether the new ContactsHub section appears below the profile photo
//     in Settings (the "Recently online" / "Favorites carousel" UX from the
//     WABetaInfo article);
//   • whether the Evolve About M1 row appears in Settings/Profile;
//   • whether the WAFFLE-switching button appears in the tab bar.
//
// Each gate is a plain BOOL no-arg instance method on a concrete ObjC class
// (located via __objc_classlist scan of the 26.x WhatsApp main binary).
// They are *not* Swift-pure, so MSHookMessageEx works without contortion.
//
// Master pref
// ───────────
// One shared user-defaults key controls the whole feature family:
//
//     wagr_metab_master_enabled
//
// Set via the WATweaks panel ("Secret Menus" → "Modo Me-Tab / Contacts Hub
// / About Evolve"). When the master is ON every hooked selector returns YES;
// when it is OFF each hooked selector returns whatever WhatsApp's original
// implementation returned, so the user can flip the feature off cleanly.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

static NSString * const kWAGRMeTabMaster = @"wagr_metab_master_enabled";

static BOOL WAGRMeTabMasterEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRMeTabMaster];
}

// One entry per (class, selector) we want to flip. Keeping this list as
// data (not code) makes it easy to extend without touching the hook body.
typedef struct {
    __unsafe_unretained NSString *className;
    __unsafe_unretained NSString *selectorName;
    __unsafe_unretained NSString *note;
} WAGRMeTabTarget;

static const WAGRMeTabTarget kMeTabTargets[] = {
    // Contacts Hub / Me Tab
    {@"WASettingsViewController",       @"isMeTabEnabled",
     @"Master gate for the new Me Tab Settings layout (avatar at top, hub below)."},
    {@"WASettingsNavigationController", @"isMeTabProfilePictureEntrypointEnabled",
     @"Tappable profile picture as entry point to the Contacts Hub."},
    {@"WAContactPickerTableViewController", @"shouldShowRecentlyOnlineSuggestedContacts",
     @"Shows the 'recently online' suggestion row inside the contact picker."},
    // About Evolve — both Settings and Profile sides query their own copy.
    {@"WASettingsViewController",       @"isEvolveAboutM1Enabled",
     @"About Evolve M1 row in Settings."},
    {@"WAProfileViewController",        @"isEvolveAboutM1Enabled",
     @"About Evolve M1 row in user profile."},
    {@"WAPrivacySettingsViewController",@"isEvolveAboutEnabled",
     @"About Evolve toggle in Privacy Settings."},
    // Waffle (Meta family switcher) — affects the tab-bar account switcher.
    {@"WATabBarController",             @"isWaffleSwitchingEnabled",
     @"Meta family account switcher button in the tab bar."},
};

#define MTM_COUNT (sizeof(kMeTabTargets)/sizeof(kMeTabTargets[0]))

typedef BOOL (*WAGRMeTabBoolIMP)(id, SEL);
static NSMutableDictionary<NSString *, NSValue *> *gMeTabOrig = nil;

static BOOL hookMeTabBool(id self, SEL _cmd) {
    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     NSStringFromClass([self class]),
                     NSStringFromSelector(_cmd)];
    WAGRMeTabBoolIMP orig = NULL;
    NSValue *v = gMeTabOrig[key];
    if (v) orig = reinterpret_cast<WAGRMeTabBoolIMP>([v pointerValue]);
    BOOL original = orig ? orig(self, _cmd) : NO;

    // Per-selector override takes precedence over the master pref so the
    // user can flip individual entries from the catalog UI for fine tuning.
    NSString *overrideKey = [NSString stringWithFormat:
        @"wagr.override|objc|%@|inst|%@",
        NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    id overrideVal = [NSUserDefaults.standardUserDefaults objectForKey:overrideKey];
    if (overrideVal != nil) return [overrideVal boolValue];

    if (WAGRMeTabMasterEnabled()) return YES;
    return original;
}

// Install one (class, selector) target. Returns YES if newly installed.
static BOOL WAGRMeTabHookOne(NSString *className, NSString *selectorName) {
    if (!className.length || !selectorName.length) return NO;
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) return NO;

    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'B' && ret[0] != 'c') return NO;

    if (!gMeTabOrig) gMeTabOrig = [NSMutableDictionary dictionary];
    NSString *origKey = [NSString stringWithFormat:@"%@|%@", className, selectorName];
    if (gMeTabOrig[origKey]) return YES;  // idempotent

    IMP origIMP = NULL;
    MSHookMessageEx(cls, sel, (IMP)hookMeTabBool, &origIMP);
    if (!origIMP) return NO;
    gMeTabOrig[origKey] = [NSValue valueWithPointer:reinterpret_cast<const void *>(origIMP)];
    NSLog(@"[WATweaks][MeTab] hooked %@ -%@", className, selectorName);
    return YES;
}

extern "C" void WAGRMeTabEnsureHooksInstalled(void) {
    NSUInteger installed = 0;
    for (size_t i = 0; i < MTM_COUNT; i++) {
        if (WAGRMeTabHookOne(kMeTabTargets[i].className, kMeTabTargets[i].selectorName)) {
            installed++;
        }
    }
    if (installed) {
        NSLog(@"[WATweaks][MeTab] %lu hooks installed", (unsigned long)installed);
    }
}

extern "C" NSString *WAGRMeTabDiagnostic(void) {
    NSMutableArray<NSString *> *loaded = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (size_t i = 0; i < MTM_COUNT; i++) {
        NSString *cls = kMeTabTargets[i].className;
        NSString *sel = kMeTabTargets[i].selectorName;
        NSString *origKey = [NSString stringWithFormat:@"%@|%@", cls, sel];
        if (gMeTabOrig[origKey]) {
            [loaded addObject:[NSString stringWithFormat:@"%@ -%@", cls, sel]];
        } else {
            [missing addObject:[NSString stringWithFormat:@"%@ -%@", cls, sel]];
        }
    }
    return [NSString stringWithFormat:
            @"master=%@\n"
            @"installed=%lu / %lu\n"
            @"hooked: %@\n"
            @"missing: %@",
            WAGRMeTabMasterEnabled() ? @"ON" : @"OFF",
            (unsigned long)loaded.count, (unsigned long)MTM_COUNT,
            loaded.count ? [loaded componentsJoinedByString:@", "] : @"none",
            missing.count ? [missing componentsJoinedByString:@", "] : @"none"];
}

__attribute__((constructor))
static void WAGRMeTabCtor(void) {
    @autoreleasepool {
        // Priority install at constructor time, plus delayed retries for the
        // cold-launch case where the Settings/Privacy/Profile classes are
        // registered on a slight lag.
        WAGRMeTabEnsureHooksInstalled();
        double delays[] = { 0.4, 1.2, 3.0, 6.0 };
        for (int i = 0; i < (int)(sizeof(delays)/sizeof(delays[0])); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(),
                           ^{ WAGRMeTabEnsureHooksInstalled(); });
        }
    }
}
