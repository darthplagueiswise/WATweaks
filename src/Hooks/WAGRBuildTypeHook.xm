// WAGRBuildTypeHook.xm
//
// SharedModules exports WABuildTypeValue(void). LIEF confirms the main
// executable imports it; Capstone shows an integer return with no arguments.
// The function reads NSBundle ConfigType and returns 2 for Beta, 3 for Debug/
// another explicit non-empty configuration, and 0 when no ConfigType exists.
//
// This is an imported C function, so the hook is intentionally fishhook-based,
// latched once at launch, and requires an app restart. It is independent from
// the live Objective-C employee/debug-menu getters.

#import <Foundation/Foundation.h>
#import <stdint.h>
#import "../WAPrefix.h"
#import "../../modules/fishhook/fishhook.h"

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void);

static uint64_t (*orig_WABuildTypeValue)(void) = NULL;
static BOOL gWAGRForceDebugBuildLatched = NO;
static BOOL gWAGRBuildTypeRebound = NO;

static uint64_t replaced_WABuildTypeValue(void) {
    if (gWAGRForceDebugBuildLatched) return 3ULL;
    return orig_WABuildTypeValue ? orig_WABuildTypeValue() : 0ULL;
}

extern "C" NSString *WAGRBuildTypeDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"forceDebugBuild(latched)=%@\nfishhook=%@\norig=%p\nforcedValue=3 (Debug ConfigType path)",
        gWAGRForceDebugBuildLatched ? @"ON" : @"OFF",
        gWAGRBuildTypeRebound ? @"YES" : @"NO",
        (void *)orig_WABuildTypeValue];
}

__attribute__((constructor))
static void WAGRBuildTypeHookCtor(void) {
    @autoreleasepool {
        // Cheap launch-time read. This C-function preference is deliberately
        // latched; changing it in the UI requires restarting WhatsApp.
        gWAGRForceDebugBuildLatched =
            [[NSUserDefaults standardUserDefaults] boolForKey:WA_PREF_FORCE_DEBUG_BUILD];
        if (!gWAGRForceDebugBuildLatched) return;

        struct rebinding binding = {
            "WABuildTypeValue",
            (void *)replaced_WABuildTypeValue,
            (void **)&orig_WABuildTypeValue,
        };
        int result = rebind_symbols(&binding, 1);
        gWAGRBuildTypeRebound = (result == 0 && orig_WABuildTypeValue != NULL);
        NSLog(@"[WATweaks][BuildType] fishhook result=%d orig=%p force=Debug(3)",
              result, (void *)orig_WABuildTypeValue);

        // Direct class/selector install only; the expensive AB scan remains
        // user-triggered. This also patches a Developer screen opened through
        // WhatsApp's own navigation when Force Debug Build is the only toggle.
        WAGRDebugMenuInstrumentationEnsureInstalled();
    }
}
