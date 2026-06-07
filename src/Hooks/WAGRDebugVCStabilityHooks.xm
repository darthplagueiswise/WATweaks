// WAGRDebugVCStabilityHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic guard rail for experimental hidden Debug VC instantiation.
//
// IMPORTANT:
// Do not patch WAIsLiquidGlassEnabled or FBAnalyticsDeleteLegacyLogPathIfExists
// in sideloaded builds.
//
// The crash report from 2026-05-22 shows:
//   EXC_BAD_ACCESS / SIGKILL
//   termination namespace: CODESIGNING
//   indicator: Invalid Page
//   pc: SharedModules:WAIsLiquidGlassEnabled
//
// That means the previous C-function hook modified an executable page in
// SharedModules.__TEXT and iOS killed the process for invalid code signing.
// This file must remain ObjC-only / diagnostic-only. Debug VC stability has to
// be solved through upstream gates and native presentation paths, not by
// modifying C functions in SharedModules at launch.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"

static BOOL gWAGRDebugVCActive = NO;

extern "C" void WAGRDebugVCStabilitySetActive(BOOL active) {
    gWAGRDebugVCActive = active;
}

extern "C" void WAGRDebugVCStabilityEnsureInstalled(void) {
    // Intentionally no-op.
    //
    // Keep the symbol so WAGRDebugVCInstantiatorVC can call it, but do not
    // modify WAIsLiquidGlassEnabled / FBAnalyticsDeleteLegacyLogPathIfExists.
    // Doing so caused CODESIGNING Invalid Page on launch.
}

extern "C" NSString *WAGRDebugVCStabilityDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"installed=NO\nactive=%@\nWAIsLiquidGlassEnabled=not modified (codesign-safe)\nFBAnalyticsDeleteLegacyLogPathIfExists=not modified (codesign-safe)\npolicy=disabled C-function modification after CODESIGNING Invalid Page crash",
            gWAGRDebugVCActive ? @"YES" : @"NO"];
}
