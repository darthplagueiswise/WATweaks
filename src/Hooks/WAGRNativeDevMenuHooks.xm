// WAGRNativeDevMenuHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Single owner of the hooks that unlock WhatsApp's native Developer Menu.
// Constructor path is Watusi-style: fixed class/selector lookups + hook install
// only. State reads go through WAGRGateStore/WAGRPref; no legacy override-key
// storage is used here.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRLog.h"

// ── Original IMPs ────────────────────────────────────────────────────────────
typedef BOOL (*BoolIMP)(id, SEL);
typedef id   (*IDIMP)(id, SEL);
typedef id   (*InitCtxIMP)(id, SEL, id);

extern "C" void WAGRRememberUserContext(id ctx, NSString *source);
extern "C" id WAGRCurrentUserContext(void);

static BoolIMP orig_dmAllowed = NULL;
static BoolIMP orig_dmShortcutEnabled = NULL;
static IDIMP orig_debugVCUserContext = NULL;
static InitCtxIMP orig_debugVCInitWithUserContext = NULL;
static InitCtxIMP orig_privateExpInitWithUserContext = NULL;

static BOOL gDevMenuHooked  = NO;
static BOOL gShortcutHooked = NO;
static BOOL gDebugVCHooked = NO;
static BOOL gPrivateExpVCHooked = NO;

static BOOL WAGRGateForcedOn(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && WAGRGateGet(selectorName);
}


// ── Real userContext capture ────────────────────────────────────────────────
// WADebugViewController is the reliable native owner. When WhatsApp creates it
// through DebugMenuProvider it passes the account/session-bound userContext.
// Cache that object and reuse it for PrivateExperimentationDebugViewController.
static id hookDebugVCInitWithUserContext(id self, SEL _cmd, id ctx) {
    if (ctx) {
        WAGRLogAppendF(@"[DebugVC] initWithUserContext arg=%@ (%p)", NSStringFromClass([ctx class]), (__bridge void *)ctx);
        WAGRRememberUserContext(ctx, @"WADebugViewController initWithUserContext: arg");
    }
    id result = orig_debugVCInitWithUserContext ? orig_debugVCInitWithUserContext(self, _cmd, ctx) : self;
    if (ctx) WAGRRememberUserContext(ctx, @"WADebugViewController initWithUserContext: result");
    return result;
}

static id hookDebugVCUserContext(id self, SEL _cmd) {
    id ctx = orig_debugVCUserContext ? orig_debugVCUserContext(self, _cmd) : nil;
    if (ctx) {
        WAGRLogAppendF(@"[DebugVC] userContext getter=%@ (%p)", NSStringFromClass([ctx class]), (__bridge void *)ctx);
        WAGRRememberUserContext(ctx, @"WADebugViewController userContext getter");
    }
    return ctx;
}

static id hookPrivateExpInitWithUserContext(id self, SEL _cmd, id ctx) {
    id realCtx = ctx ?: WAGRCurrentUserContext();
    if (realCtx) {
        WAGRLogAppendF(@"[PrivateExpVC] initWithUserContext arg/cache=%@ (%p)", NSStringFromClass([realCtx class]), (__bridge void *)realCtx);
        WAGRRememberUserContext(realCtx, @"PrivateExperimentation initWithUserContext: arg/cache");
    } else {
        WAGRLogAppend(@"[PrivateExpVC] initWithUserContext received nil and cache is nil");
    }

    id instance = orig_privateExpInitWithUserContext ? orig_privateExpInitWithUserContext(self, _cmd, realCtx) : self;
    if (instance) {
        uintptr_t base = (uintptr_t)(__bridge void *)instance;
        void *managerWord0 = NULL;
        void *ctxWord = NULL;
        @try {
            managerWord0 = *(void **)(base + 0x8);
            ctxWord = *(void **)(base + 0x30);
        } @catch (__unused NSException *ex) {}
        WAGRLogAppendF(@"[PrivateExpVC] initialized instance=%@ managerWord@0x8=%p userContext@0x30=%p", NSStringFromClass([instance class]), managerWord0, ctxWord);
    }
    return instance;
}

static void installUserContextCaptureHooks(void) {
    if (!gDebugVCHooked) {
        Class dbg = NSClassFromString(@"WADebugViewController");
        if (dbg) {
            SEL initSel = NSSelectorFromString(@"initWithUserContext:");
            if (class_getInstanceMethod(dbg, initSel)) {
                MSHookMessageEx(dbg, initSel, (IMP)hookDebugVCInitWithUserContext, (IMP *)&orig_debugVCInitWithUserContext);
            }
            SEL ctxSel = NSSelectorFromString(@"userContext");
            if (class_getInstanceMethod(dbg, ctxSel)) {
                MSHookMessageEx(dbg, ctxSel, (IMP)hookDebugVCUserContext, (IMP *)&orig_debugVCUserContext);
            }
            gDebugVCHooked = (orig_debugVCInitWithUserContext != NULL || orig_debugVCUserContext != NULL);
        }
    }

    if (!gPrivateExpVCHooked) {
        Class pe = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
        if (!pe) pe = NSClassFromString(@"WAPrivateExperimentation.PrivateExperimentationDebugViewController");
        if (pe) {
            SEL initSel = NSSelectorFromString(@"initWithUserContext:");
            if (class_getInstanceMethod(pe, initSel)) {
                MSHookMessageEx(pe, initSel, (IMP)hookPrivateExpInitWithUserContext, (IMP *)&orig_privateExpInitWithUserContext);
                gPrivateExpVCHooked = (orig_privateExpInitWithUserContext != NULL);
            }
        }
    }
}

// ── Master gate ──────────────────────────────────────────────────────────────
// Returns YES if any relevant master pref or runtime-browser gate is ON.
static BOOL WAGRNativeDevAllowed(void) {
    if (WAGRPref(kWAGRDebugMenuNative)
        || WAGRPref(kWAGRInternalMaster)
        || WAGRPref(kWAGREmployeeMaster)
        || WAGRPref(kWAGRDebugMode)) {
        return YES;
    }

    // Runtime Avançado now writes selector names through WAGRGateStore. Do not
    // use WAGROverrideKey/WAGRHasOverride here: those belonged to the removed
    // duplicated UI/storage path.
    if (WAGRGateForcedOn(@"isDebugMenuAllowed") ||
        WAGRGateForcedOn(@"isDebugMenuShortcutEnabled")) {
        return YES;
    }
    return NO;
}

// ── Trampolines ──────────────────────────────────────────────────────────────
static BOOL hookDevAllowed(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmAllowed ? orig_dmAllowed(self, _cmd) : NO;
}

static BOOL hookDevShortcut(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmShortcutEnabled ? orig_dmShortcutEnabled(self, _cmd) : NO;
}

// ── Method presence probes ───────────────────────────────────────────────────
static BOOL classHasInstanceMethod(Class cls, SEL sel) {
    return cls && sel && class_getInstanceMethod(cls, sel) != NULL;
}

static BOOL classHasClassMethod(Class cls, SEL sel) {
    return cls && sel && class_getClassMethod(cls, sel) != NULL;
}

// ── Installer ────────────────────────────────────────────────────────────────
static void installNativeDevMenuHooks(void) {
    installUserContextCaptureHooks();
    if (gDevMenuHooked && gShortcutHooked) return;

    NSArray *candidates = @[
        @"_TtC15WADebugMenuMain17DebugMenuProvider",
        @"WASettingsViewController",
        @"WASettingsTableViewController",
        @"WANewSettingsViewController",
        @"WASettingsNavTableViewController",
        @"WASettingsNavigationController",
    ];

    SEL allowedSel  = NSSelectorFromString(@"isDebugMenuAllowed");
    SEL shortcutSel = NSSelectorFromString(@"isDebugMenuShortcutEnabled");

    for (NSString *n in candidates) {
        Class cls = NSClassFromString(n);
        if (!cls) continue;

        if (!gDevMenuHooked) {
            if (classHasInstanceMethod(cls, allowedSel)) {
                MSHookMessageEx(cls, allowedSel, (IMP)hookDevAllowed, (IMP *)&orig_dmAllowed);
                gDevMenuHooked = (orig_dmAllowed != NULL);
            } else if (classHasClassMethod(cls, allowedSel)) {
                MSHookMessageEx(object_getClass(cls), allowedSel, (IMP)hookDevAllowed, (IMP *)&orig_dmAllowed);
                gDevMenuHooked = (orig_dmAllowed != NULL);
            }
        }

        if (!gShortcutHooked) {
            if (classHasInstanceMethod(cls, shortcutSel)) {
                MSHookMessageEx(cls, shortcutSel, (IMP)hookDevShortcut, (IMP *)&orig_dmShortcutEnabled);
                gShortcutHooked = (orig_dmShortcutEnabled != NULL);
            } else if (classHasClassMethod(cls, shortcutSel)) {
                MSHookMessageEx(object_getClass(cls), shortcutSel, (IMP)hookDevShortcut, (IMP *)&orig_dmShortcutEnabled);
                gShortcutHooked = (orig_dmShortcutEnabled != NULL);
            }
        }

        if (gDevMenuHooked && gShortcutHooked) break;
    }

    WAGRLogAppendF(@"[NativeDevMenu] install pass: allowed=%@ shortcut=%@ debugVCHook=%@ privateExpHook=%@",
          gDevMenuHooked  ? @"YES" : @"NO",
          gShortcutHooked ? @"YES" : @"NO",
          gDebugVCHooked ? @"YES" : @"NO",
          gPrivateExpVCHooked ? @"YES" : @"NO");
}

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) {
    installNativeDevMenuHooks();
}

extern "C" NSString *WAGRNativeDevMenuDiagnosticText(void) {
    Class swiftCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    Class debugVC = NSClassFromString(@"WADebugViewController");
    Class peVC = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
    return [NSString stringWithFormat:
            @"swiftClassLoaded=%@\nallowedHook=%@\nshortcutHook=%@\ndebugVC=%@\ndebugVCHooks=%@\nprivateExpVC=%@\nprivateExpInitHook=%@\ncachedUserContext=%@",
            swiftCls ? @"YES" : @"NO",
            gDevMenuHooked  ? @"YES" : @"NO",
            gShortcutHooked ? @"YES" : @"NO",
            debugVC ? @"YES" : @"NO",
            gDebugVCHooked ? @"YES" : @"NO",
            peVC ? @"YES" : @"NO",
            gPrivateExpVCHooked ? @"YES" : @"NO",
            WAGRCurrentUserContext() ? NSStringFromClass([WAGRCurrentUserContext() class]) : @"nil"];
}

__attribute__((constructor))
static void WAGRNativeDevMenuCtor(void) {
    @autoreleasepool {
        installNativeDevMenuHooks();
    }
}
