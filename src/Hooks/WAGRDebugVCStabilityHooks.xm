// WAGRDebugVCStabilityHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Targeted guard rails for experimental hidden Debug VC instantiation.
//
// The decoded crash path was:
//   hidden Swift Debug VC init/dismiss
//     -> WAIsLiquidGlassEnabled
//     -> FBAnalyticsDeleteLegacyLogPathIfExists
//     -> Swift runtime trap / assertion
//
// This file does not make direct instantiation "safe" in the general sense;
// Swift traps are process-fatal. It only removes two known unstable edges while
// a Debug VC is being experimentally opened through WAGRDebugVCInstantiatorVC.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

static BOOL gWAGRDebugVCStabilityInstalled = NO;
static BOOL gWAGRDebugVCActive = NO;
static BOOL gWAGRHookedWAIsLiquidGlassEnabled = NO;
static BOOL gWAGRHookedFBAnalyticsDeleteLegacyLogPath = NO;

static BOOL (*orig_WAIsLiquidGlassEnabled)(void) = NULL;
static void (*orig_FBAnalyticsDeleteLegacyLogPathIfExists)(void) = NULL;

static BOOL hook_WAIsLiquidGlassEnabled(void) {
    if (gWAGRDebugVCActive) {
        // During raw hidden Debug VC construction, prefer the non-LiquidGlass
        // path. The LG path has been observed to reach FBAnalytics cleanup and
        // trip Swift assertions when the native debug environment is missing.
        return NO;
    }
    if (orig_WAIsLiquidGlassEnabled) return orig_WAIsLiquidGlassEnabled();
    return NO;
}

static void hook_FBAnalyticsDeleteLegacyLogPathIfExists(void) {
    if (gWAGRDebugVCActive) {
        return;
    }
    if (orig_FBAnalyticsDeleteLegacyLogPathIfExists) {
        orig_FBAnalyticsDeleteLegacyLogPathIfExists();
    }
}

static void WAGRHookFunctionByName(const char *name, void *replacement, void **origOut, BOOL *flagOut) {
    if (!name || !replacement || !origOut || !flagOut || *flagOut) return;
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) return;
    MSHookFunction(sym, replacement, origOut);
    *flagOut = (*origOut != NULL);
}

extern "C" void WAGRDebugVCStabilitySetActive(BOOL active) {
    gWAGRDebugVCActive = active;
}

extern "C" void WAGRDebugVCStabilityEnsureInstalled(void) {
    if (gWAGRDebugVCStabilityInstalled &&
        gWAGRHookedWAIsLiquidGlassEnabled &&
        gWAGRHookedFBAnalyticsDeleteLegacyLogPath) {
        return;
    }

    WAGRHookFunctionByName("WAIsLiquidGlassEnabled",
                           (void *)&hook_WAIsLiquidGlassEnabled,
                           (void **)&orig_WAIsLiquidGlassEnabled,
                           &gWAGRHookedWAIsLiquidGlassEnabled);

    WAGRHookFunctionByName("FBAnalyticsDeleteLegacyLogPathIfExists",
                           (void *)&hook_FBAnalyticsDeleteLegacyLogPathIfExists,
                           (void **)&orig_FBAnalyticsDeleteLegacyLogPathIfExists,
                           &gWAGRHookedFBAnalyticsDeleteLegacyLogPath);

    gWAGRDebugVCStabilityInstalled = YES;
}

extern "C" NSString *WAGRDebugVCStabilityDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"installed=%@\nactive=%@\nWAIsLiquidGlassEnabled=%@\nFBAnalyticsDeleteLegacyLogPathIfExists=%@",
            gWAGRDebugVCStabilityInstalled ? @"YES" : @"NO",
            gWAGRDebugVCActive ? @"YES" : @"NO",
            gWAGRHookedWAIsLiquidGlassEnabled ? @"HOOKED" : @"missing/not exported",
            gWAGRHookedFBAnalyticsDeleteLegacyLogPath ? @"HOOKED" : @"missing/not exported"];
}

__attribute__((constructor))
static void WAGRDebugVCStabilityCtor(void) {
    @autoreleasepool {
        WAGRDebugVCStabilityEnsureInstalled();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRDebugVCStabilityEnsureInstalled(); });
    }
}
