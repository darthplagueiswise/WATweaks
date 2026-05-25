// WAGRNativeDevMenuHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Native WhatsApp Debug Menu gate owner.
//
// Target confirmed from WhatsApp(10):
//   _TtC15WADebugMenuMain17DebugMenuProvider
//     -isDebugMenuAllowed
//     -isDebugMenuShortcutEnabled
//     -debugViewController
//     -presentDebugControllerIfNeeded
//
// This file does not create a fake WAAB menu. It only unlocks the native
// provider/controller path and primes the WAAB/private-experimentation gates
// through WAGRGateStore when the user asks to open the native menu.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRGateHooksEnsureInstalled(void);

// ── Original IMPs ────────────────────────────────────────────────────────────
typedef BOOL (*BoolIMP)(id, SEL);
static BoolIMP orig_dmAllowed = NULL;
static BoolIMP orig_dmShortcutEnabled = NULL;
static BoolIMP orig_serverPropsDisableExperimental = NULL;

static BOOL gDevMenuHooked  = NO;
static BOOL gShortcutHooked = NO;
static BOOL gServerPropsDisableExperimentalHooked = NO;

static BOOL WAGRGateForcedOn(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && WAGRGateGet(selectorName);
}

static BOOL WAGRGateForcedOff(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && !WAGRGateGet(selectorName);
}

// Called by the launcher before opening native UI. This is intentionally not
// called from constructor: it writes prefs and installs optional hooks only on
// explicit user action.
extern "C" void WAGRNativeDebugActivateSupportGates(void) {
    WAGRGateSet(@"isDebugMenuAllowed", YES);
    WAGRGateSet(@"isDebugMenuShortcutEnabled", YES);

    WAGRGateSet(@"waios_mc_debug_ui_enabled", YES);
    WAGRGateSet(@"whatsbroken_enabled", YES);
    WAGRGateSet(@"private_abprop_for_dev_only", YES);
    WAGRGateSet(@"private_experimentation_should_sync", YES);
    WAGRGateSet(@"dogfooding_nudge_settings_entrypoint_enabled", YES);

    // isDebugMenuAllowed references this gate in the binary. This must be OFF.
    WAGRGateSet(@"serverPropsDisableExperimental", NO);

    WAGRGateHooksEnsureInstalled();
}

static BOOL WAGRNativeDevAllowed(void) {
    if (WAGRPref(kWAGRDebugMenuNative) ||
        WAGRPref(kWAGRInternalMaster) ||
        WAGRPref(kWAGREmployeeMaster) ||
        WAGRPref(kWAGRDebugMode)) {
        return YES;
    }

    return WAGRGateForcedOn(@"isDebugMenuAllowed") ||
           WAGRGateForcedOn(@"isDebugMenuShortcutEnabled") ||
           WAGRGateForcedOn(@"waios_mc_debug_ui_enabled") ||
           WAGRGateForcedOn(@"private_abprop_for_dev_only");
}

static BOOL hookDevAllowed(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmAllowed ? orig_dmAllowed(self, _cmd) : NO;
}

static BOOL hookDevShortcut(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmShortcutEnabled ? orig_dmShortcutEnabled(self, _cmd) : NO;
}

static BOOL hookServerPropsDisableExperimental(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed() || WAGRGateForcedOff(@"serverPropsDisableExperimental")) return NO;
    return orig_serverPropsDisableExperimental ? orig_serverPropsDisableExperimental(self, _cmd) : NO;
}

static BOOL classHasInstanceMethod(Class cls, SEL sel) {
    return cls && sel && class_getInstanceMethod(cls, sel) != NULL;
}

static BOOL classHasClassMethod(Class cls, SEL sel) {
    return cls && sel && class_getClassMethod(cls, sel) != NULL;
}

static BOOL WAGRHookBoolNoArg(Class cls, SEL sel, BOOL classMethod, IMP replacement, BoolIMP *origOut) {
    if (!cls || !sel || !replacement || !origOut) return NO;
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'B' && ret[0] != 'c') return NO;
    Class target = classMethod ? object_getClass(cls) : cls;
    IMP orig = NULL;
    MSHookMessageEx(target, sel, replacement, &orig);
    if (!orig) return NO;
    *origOut = (BoolIMP)orig;
    return YES;
}

static void installNativeDevMenuHooks(void) {
    NSArray *providerCandidates = @[
        @"_TtC15WADebugMenuMain17DebugMenuProvider",
        @"WASettingsViewController",
        @"WASettingsTableViewController",
        @"WANewSettingsViewController",
        @"WASettingsNavTableViewController",
        @"WASettingsNavigationController",
    ];

    SEL allowedSel  = NSSelectorFromString(@"isDebugMenuAllowed");
    SEL shortcutSel = NSSelectorFromString(@"isDebugMenuShortcutEnabled");

    for (NSString *n in providerCandidates) {
        Class cls = NSClassFromString(n);
        if (!cls) continue;

        if (!gDevMenuHooked) {
            if (classHasInstanceMethod(cls, allowedSel)) {
                gDevMenuHooked = WAGRHookBoolNoArg(cls, allowedSel, NO, (IMP)hookDevAllowed, &orig_dmAllowed);
            } else if (classHasClassMethod(cls, allowedSel)) {
                gDevMenuHooked = WAGRHookBoolNoArg(cls, allowedSel, YES, (IMP)hookDevAllowed, &orig_dmAllowed);
            }
        }

        if (!gShortcutHooked) {
            if (classHasInstanceMethod(cls, shortcutSel)) {
                gShortcutHooked = WAGRHookBoolNoArg(cls, shortcutSel, NO, (IMP)hookDevShortcut, &orig_dmShortcutEnabled);
            } else if (classHasClassMethod(cls, shortcutSel)) {
                gShortcutHooked = WAGRHookBoolNoArg(cls, shortcutSel, YES, (IMP)hookDevShortcut, &orig_dmShortcutEnabled);
            }
        }

        if (gDevMenuHooked && gShortcutHooked) break;
    }

    if (!gServerPropsDisableExperimentalHooked) {
        SEL offSel = NSSelectorFromString(@"serverPropsDisableExperimental");
        for (NSString *n in @[ @"WAServerProperties", @"WAABProperties", @"FOAWAABPropertiesImpl" ]) {
            Class cls = NSClassFromString(n);
            if (!cls) continue;
            if (classHasClassMethod(cls, offSel)) {
                gServerPropsDisableExperimentalHooked = WAGRHookBoolNoArg(cls, offSel, YES, (IMP)hookServerPropsDisableExperimental, &orig_serverPropsDisableExperimental);
            } else if (classHasInstanceMethod(cls, offSel)) {
                gServerPropsDisableExperimentalHooked = WAGRHookBoolNoArg(cls, offSel, NO, (IMP)hookServerPropsDisableExperimental, &orig_serverPropsDisableExperimental);
            }
            if (gServerPropsDisableExperimentalHooked) break;
        }
    }

    NSLog(@"[WATweaks][NativeDevMenu] install pass: allowed=%@ shortcut=%@ disableExperimental=%@",
          gDevMenuHooked ? @"YES" : @"NO",
          gShortcutHooked ? @"YES" : @"NO",
          gServerPropsDisableExperimentalHooked ? @"YES" : @"NO");
}

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) {
    installNativeDevMenuHooks();
}

extern "C" NSString *WAGRNativeDevMenuDiagnosticText(void) {
    Class swiftCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    Class debugVC = NSClassFromString(@"WADebugViewController");
    Class privateExp = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
    return [NSString stringWithFormat:
            @"DebugMenuProvider=%@\nWADebugViewController=%@\nPrivateExperimentationVC=%@\nallowedHook=%@\nshortcutHook=%@\ndisableExperimentalHook=%@\nmcDebugUI=%@\nprivateABDevOnly=%@\nprivateExpSync=%@\ndogfoodNudge=%@\nserverPropsDisableExperimental=%@",
            swiftCls ? @"loaded" : @"missing",
            debugVC ? @"loaded" : @"missing",
            privateExp ? @"loaded" : @"missing",
            gDevMenuHooked ? @"YES" : @"NO",
            gShortcutHooked ? @"YES" : @"NO",
            gServerPropsDisableExperimentalHooked ? @"YES" : @"NO",
            WAGRGateForcedOn(@"waios_mc_debug_ui_enabled") ? @"ON" : @"system",
            WAGRGateForcedOn(@"private_abprop_for_dev_only") ? @"ON" : @"system",
            WAGRGateForcedOn(@"private_experimentation_should_sync") ? @"ON" : @"system",
            WAGRGateForcedOn(@"dogfooding_nudge_settings_entrypoint_enabled") ? @"ON" : @"system",
            WAGRGateForcedOff(@"serverPropsDisableExperimental") ? @"OFF" : @"system"];
}

__attribute__((constructor))
static void WAGRNativeDevMenuCtor(void) {
    @autoreleasepool {
        installNativeDevMenuHooks();
    }
}
