// WAGRContextHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Hooks on WAContextMain — the WhatsApp class that hosts a few of the
// dependency-provider category gates we care about.
//
// What this file owns
// ───────────────────
//   -isVerifiedChannelFeatureFlagEnabled  (verified owner: WAContextMain via
//                                          the WADependencyProviderMain3
//                                          category)
//
// History note
// ────────────
// The previous version of this file also tried to hook -isDebugMenuAllowed,
// -isDebugBuild, -isDebugMenuShortcutEnabled, -isBetaOrMoreVerbose,
// -isTestFlightApp, -listsFeatureEnabled, -smbListsFeatureEnabled and
// -avatarFeatureEnabled on WAContextMain (with a broad-scan fallback for
// -isDebugMenuAllowed). Static analysis of __objc_classlist, __objc_methlist
// and __objc_catlist of the WhatsApp binary showed that WAContextMain does
// not declare any of those selectors, in either its base methods or any of
// its categories. Hooking those was therefore dead code that produced no
// effect at runtime and competed for installation rights with
// WAGRNativeDevMenuHooks.xm (which targets the correct class for the dev
// menu gates, _TtC15WADebugMenuMain17DebugMenuProvider).
//
// To keep this file honest, those entries were removed. The only selector
// that remains is the one whose ownership we could verify in the binary,
// which is -isVerifiedChannelFeatureFlagEnabled.
//
// If a future WhatsApp build moves additional gates onto WAContextMain (or
// onto another class hosted via a similar dependency-provider category),
// adding them here is a one-line edit — append the (selector, default pref)
// pair to the install table below.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

// Public-facing pref key that controls whether the verified-channel gate is
// forced ON. Kept under its previous name so any pref the user may already
// have set is preserved across this refactor.
#define kWAGRCtxVerified  @"wagr.ctx.isVerifiedChannelFeatureFlagEnabled"

typedef BOOL (*BoolIMP)(id, SEL);
static BoolIMP    orig_verified  = NULL;
static BOOL       gCtxInstalled  = NO;
static NSUInteger gCtxHookedCount = 0;

// ── Trampoline ───────────────────────────────────────────────────────────────
// Standard "force YES when user opts in, else delegate to original" shape.
static BOOL h_verified(id self, SEL _cmd) {
    if (WAGRPref(kWAGRCtxVerified)) return YES;
    return orig_verified ? orig_verified(self, _cmd) : NO;
}

// ── Per-(class, selector) installer ──────────────────────────────────────────
// Symmetric helper to the one in WAGREmployeeHooks.xm. Strict zero-arg BOOL
// signature check keeps us from corrupting unrelated methods that happen to
// share a name.
static void hookSelectorOnClass(Class cls, const char *selCStr,
                                IMP replacement, BoolIMP *origSlot) {
    if (!cls || !selCStr || !replacement || !origSlot || *origSlot) return;
    SEL sel = sel_registerName(selCStr);

    for (int m = 0; m < 2; m++) {
        Method mth = m ? class_getClassMethod(cls, sel)
                       : class_getInstanceMethod(cls, sel);
        if (!mth) continue;
        if (method_getNumberOfArguments(mth) != 2) continue;
        char ret[8] = {0};
        method_getReturnType(mth, ret, sizeof(ret));
        if (ret[0] != 'B' && ret[0] != 'c') continue;

        Class target = m ? object_getClass(cls) : cls;
        MSHookMessageEx(target, sel, replacement, (IMP *)origSlot);
        if (*origSlot) { gCtxHookedCount++; return; }
    }
}

// ── Installer ────────────────────────────────────────────────────────────────
// Single-entry install table for what we know works. New rows go here.
static void installContextHooks(void) {
    if (gCtxInstalled) return;

    Class ctx = NSClassFromString(@"WAContextMain");
    if (ctx) {
        hookSelectorOnClass(ctx, "isVerifiedChannelFeatureFlagEnabled",
                            (IMP)h_verified, &orig_verified);
    }

    gCtxInstalled = (orig_verified != NULL);

    NSLog(@"[WATweaks][Ctx] install pass: hooked=%lu installed=%@",
          (unsigned long)gCtxHookedCount,
          gCtxInstalled ? @"YES" : @"NO");
}

// ── Public API ───────────────────────────────────────────────────────────────
extern "C" void WAGRContextHooksEnsureInstalled(void) {
    installContextHooks();
}

extern "C" NSString *WAGRContextHooksDiagnostic(void) {
    return [NSString stringWithFormat:
        @"hookedTotal=%lu\nverifiedChannel=%@\nverifiedForced=%@",
        (unsigned long)gCtxHookedCount,
        orig_verified           ? @"YES" : @"NO",
        WAGRPref(kWAGRCtxVerified) ? @"ON"  : @"OFF"];
}

// ── Constructor ──────────────────────────────────────────────────────────────
// Same retry rhythm used elsewhere in this project. We always install,
// regardless of whether the user already toggled the pref — installing the
// hook ahead of time means flipping the pref later takes effect immediately
// without requiring the user to relaunch the app.
__attribute__((constructor))
static void WAGRContextHooksCtor(void) {
    @autoreleasepool {
        // Watusi-style: install once, synchronously, during dylib load.
        installContextHooks();
    }
}
