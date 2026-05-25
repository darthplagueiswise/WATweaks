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

// ── Original IMPs ────────────────────────────────────────────────────────────
typedef BOOL (*BoolIMP)(id, SEL);
static BoolIMP orig_dmAllowed = NULL;
static BoolIMP orig_dmShortcutEnabled = NULL;

static BOOL gDevMenuHooked  = NO;
static BOOL gShortcutHooked = NO;

static BOOL WAGRGateForcedOn(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && WAGRGateGet(selectorName);
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

    NSLog(@"[WATweaks][NativeDevMenu] install pass: allowed=%@ shortcut=%@",
          gDevMenuHooked  ? @"YES" : @"NO",
          gShortcutHooked ? @"YES" : @"NO");
}

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) {
    installNativeDevMenuHooks();
}

extern "C" NSString *WAGRNativeDevMenuDiagnosticText(void) {
    Class swiftCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    return [NSString stringWithFormat:
            @"swiftClassLoaded=%@\nallowedHook=%@\nshortcutHook=%@",
            swiftCls ? @"YES" : @"NO",
            gDevMenuHooked  ? @"YES" : @"NO",
            gShortcutHooked ? @"YES" : @"NO"];
}

__attribute__((constructor))
static void WAGRNativeDevMenuCtor(void) {
    @autoreleasepool {
        installNativeDevMenuHooks();
    }
}
