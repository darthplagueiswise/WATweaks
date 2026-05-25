// WAGRAccountEligibilityHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Why this file exists
// ────────────────────
// WAAuraHooks.xm targets WAAuraGating + the two GatedSubscriptionProvider /
// GatedBenefitProvider Swift classes. Static analysis of SharedModules shows
// those two Swift classes expose only one ObjC method (`abPropsDidUpdate`)
// at the runtime bridge — every other entry point is Swift-pure and cannot
// be hooked by MSHookMessageEx. So hooking them is a no-op.
//
// The real gate that decides whether the Subscriptions / WA Plus Settings
// row appears is `WAAccountEligibility -isEligibleForSubscriptions`. That
// class lives in SharedModules and exposes 31 ObjC-visible BOOL methods,
// all in the `isEligibleFor*` family. We hook a small whitelist of
// subscription-related ones; we deliberately do NOT blanket-hook every
// `isEligibleFor*` method because some of them gate unrelated invariants
// like linking mode or device-pairing flows, and forcing those to YES
// could destabilise the app.
//
// Master toggle reuses the existing Aura simulation pref so a single
// switch from the user enables both the WAAuraGating overrides (handled
// by WAAuraHooks.xm) and the WAAccountEligibility overrides (handled here).
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

// The "is Aura simulation on?" predicate is owned by
// WAGRAuraNavigationHooks.xm. We re-declare it here so we read the same
// source of truth instead of duplicating the pref-key list.
extern "C" BOOL WAGRAuraSimulationEnabled(void);

typedef BOOL (*WAGREligBoolIMP)(id, SEL);

// Stores the original IMP for every selector we have replaced on
// WAAccountEligibility (and the PAA/PMTA Swift gatekeepers). Keyed by
// "className|selectorName" so a runtime classes that shares a selector
// name with a sibling class never collides.
static NSMutableDictionary<NSString *, NSValue *> *gEligOrig = nil;

// Whitelist of selectors that we are willing to flip to YES. Every entry
// here was confirmed by static analysis of SharedModules; the comments
// describe the visible UI surface that the selector unlocks.
static NSArray<NSString *> *WAGRAccountEligibilityTargetSelectors(void) {
    return @[
        // Subscriptions row in Settings — the headline gate for Aura.
        @"isEligibleForSubscriptions",
        // AI subscription entry point (Meta AI / Imagine surfaces).
        @"isEligibleForMetaAI",
        // FOA bookmarks (Instagram / Threads / FB / Meta Horizon / Meta AI
        // app cells in Settings). The Settings VC checks this before
        // adding the Meta family bookmark row.
        @"isEligibleForFOABookmarks",
        // Waffle home — also visible in Settings as a redirect row on
        // certain builds, useful for surface coverage.
        @"isPAAEligibleForWaffle",
        // Sponsor controls — adds the SponsorControlsCell to Settings.
        @"isAccountEligibleForSettingsSponsorControls",
        @"isSponsor",
        // Optional, kept off the default ON path: Payments. Many builds
        // need a regional/B12 check, so we surface it as an explicit
        // opt-in pref instead of forcing it.
        @"isEligibleForPayments",
    ];
}

// Selectors that are deliberately opt-in only — they unlock features that
// can break account state if forced without the supporting flags.
static BOOL WAGRAccountEligibilityIsOptIn(NSString *sel) {
    if ([sel isEqualToString:@"isEligibleForPayments"]) {
        return !WAGRPref(@"wagr.settingsrows.force_payments");
    }
    return NO;
}

static BOOL hook_eligibilityBool(id self, SEL _cmd) {
    NSString *sel = NSStringFromSelector(_cmd);
    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     NSStringFromClass([self class]), sel];

    WAGREligBoolIMP orig = NULL;
    NSValue *v = gEligOrig[key];
    if (v) orig = reinterpret_cast<WAGREligBoolIMP>([v pointerValue]);
    BOOL original = orig ? orig(self, _cmd) : NO;

    // Two-tier policy:
    //   1) If the user explicitly stored a schema-v2 override for this
    //      selector (key = selector name, value = NSNumber BOOL), it wins.
    //   2) Otherwise, if the Aura master pref is on AND this is not an
    //      opt-in-only selector, we force YES.
    if (WAGRGateIsSet(sel)) {
        return WAGRGateGet(sel);
    }

    if (WAGRAuraSimulationEnabled() && !WAGRAccountEligibilityIsOptIn(sel)) {
        return YES;
    }

    return original;
}

// Returns YES iff the class exists at runtime and we successfully replaced
// the selector. Idempotent — calling twice does not double-hook.
static BOOL WAGREligHookOne(NSString *className, NSString *selectorName) {
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

    if (!gEligOrig) gEligOrig = [NSMutableDictionary dictionary];
    NSString *origKey = [NSString stringWithFormat:@"%@|%@", className, selectorName];
    if (gEligOrig[origKey]) return YES;  // already installed

    IMP origIMP = NULL;
    MSHookMessageEx(cls, sel, (IMP)hook_eligibilityBool, &origIMP);
    if (!origIMP) return NO;

    gEligOrig[origKey] = [NSValue valueWithPointer:reinterpret_cast<const void *>(origIMP)];
    NSLog(@"[WATweaks][AccountElig] hooked %@ -%@", className, selectorName);
    return YES;
}

// Classes we are willing to walk for the whitelist. The PAA / PMTA Swift
// gatekeepers are siblings of WAAccountEligibility that decide linking-mode
// state — they expose `isLinkingModeOn`, `isLinkingEnabled`, etc., which
// are not in our whitelist, so they won't get patched unless we extend.
// Keeping the array means future selectors on those classes can be added
// to the whitelist without touching the candidate list.
static NSArray<NSString *> *WAGREligibilityCandidateClasses(void) {
    return @[
        @"WAAccountEligibility",
        @"_TtC20WAAccountEligibility13PAAGatekeeper",
        @"_TtC20WAAccountEligibility14PMTAGatekeeper",
    ];
}

extern "C" void WAGRAccountEligibilityEnsureHooksInstalled(void) {
    NSArray<NSString *> *classes  = WAGREligibilityCandidateClasses();
    NSArray<NSString *> *selectors = WAGRAccountEligibilityTargetSelectors();
    NSUInteger installed = 0;
    for (NSString *cls in classes) {
        for (NSString *sel in selectors) {
            if (WAGREligHookOne(cls, sel)) installed++;
        }
    }
    if (installed) {
        NSLog(@"[WATweaks][AccountElig] %lu eligibility selectors installed across %lu classes",
              (unsigned long)installed, (unsigned long)classes.count);
    }
}

extern "C" NSString *WAGRAccountEligibilityDiagnostic(void) {
    NSMutableArray<NSString *> *loaded = [NSMutableArray array];
    for (NSString *cls in WAGREligibilityCandidateClasses()) {
        if (NSClassFromString(cls)) [loaded addObject:cls];
    }
    return [NSString stringWithFormat:
            @"installed=%lu\nclasses found=%@\nopt-in selectors=isEligibleForPayments\n"
             "master pref reused from Aura simulation\nWAAuraSimulationEnabled=%@",
            (unsigned long)gEligOrig.count,
            loaded.count ? [loaded componentsJoinedByString:@", "] : @"none",
            WAGRAuraSimulationEnabled() ? @"YES" : @"NO"];
}

static void WAGRAccountEligibilityDyldCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh; (void)vmaddr_slide;
    dispatch_async(dispatch_get_main_queue(), ^{ WAGRAccountEligibilityEnsureHooksInstalled(); });
}

__attribute__((constructor))
static void WAGRAccountEligibilityCtor(void) {
    @autoreleasepool {
        WAGRAccountEligibilityEnsureHooksInstalled();
        _dyld_register_func_for_add_image(WAGRAccountEligibilityDyldCallback);
        double delays[] = { 0.25, 0.75, 1.5 };
        for (int i = 0; i < (int)(sizeof(delays)/sizeof(delays[0])); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRAccountEligibilityEnsureHooksInstalled(); });
        }
    }
}
