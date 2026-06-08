// WAGRBootstrap.xm — single coordinated startup path for WATweaks.
//
// This file is the only constructor in the main tweak target.  Individual hook
// files expose Ensure/Install functions; bootstrap decides when they run.
// The goal is predictable launch behavior: no duplicated delayed retries, no
// menu-owned hook startup side effects, and one persistence migration pass.

#import <Foundation/Foundation.h>
#import "../WAUtils.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRSettingsRowsNativeEnsureHooksInstalled(void);
extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void);
extern "C" void WAGRDogfoodEnsureHooksInstalled(void);
extern "C" void WAGRContextHooksEnsureInstalled(void);
extern "C" void WAGRAccountEligibilityEnsureHooksInstalled(void);
extern "C" void WAGRAuraEnsureHooksInstalled(void);
extern "C" void WAGRAuraEnsureNavigationHooksInstalled(void);
extern "C" void WAGRWAABEnsureHooksInstalled(void);
extern "C" void WAGRGateHooksEnsureInstalled(void);
extern "C" void WAGRLGEnsureHooksInstalled(void);
extern "C" NSUInteger WAGRReinstallPersistedHooks(void);
extern "C" void WAInstallKeychainPatchIfNeeded(void);

static void WAGRBootstrapInstallFixedHooks(void) {
    WARegisterDefaults();
    WAGRWipeLegacyStorageIfNeeded();

    // UI entry and native developer-menu hooks are cheap fixed hooks and should
    // be ready before Settings appears.
    WAGRSettingsRowsNativeEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRDebugMenuInstrumentationEnsureInstalled();

    // Runtime gates: one WAAB owner, then fixed gate families.
    WAGRGateHooksEnsureInstalled();
    WAGRWAABEnsureHooksInstalled();
    WAGRDogfoodEnsureHooksInstalled();
    WAGRContextHooksEnsureInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRAuraEnsureNavigationHooksInstalled();
    WAGRLGEnsureHooksInstalled();

    // Persisted browser hooks and optional keychain fishhooks are applied once,
    // after the storage migration has canonicalized keys.
    (void)WAGRReinstallPersistedHooks();
    WAInstallKeychainPatchIfNeeded();
}

__attribute__((constructor))
static void WAGRBootstrapConstructor(void) {
    @autoreleasepool {
        WAGRBootstrapInstallFixedHooks();

        // One late pass catches Swift/SharedModules classes that arrive after
        // dyld constructors.  Keep it centralized to avoid per-file retry storms.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WAGRBootstrapInstallFixedHooks();
        });
    }
}
