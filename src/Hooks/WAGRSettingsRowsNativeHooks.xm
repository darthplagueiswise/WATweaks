// WAGRSettingsRowsNativeHooks.xm
//
// Settings-row injection is intentionally disabled.
// WATweaks entrypoint is the guarded long-press hook in Tweak.x.
// Keep these public symbols as compatibility shims for menu diagnostics,
// backups/import paths, and older call sites.

#import <Foundation/Foundation.h>

static NSUInteger gEnsureAttempts = 0;

extern "C" void WAGRSettingsRowsNativeEnsureHooksInstalled(void) {
    gEnsureAttempts++;
}

extern "C" void WAGRSettingsRowsNativeInjectIfPossible(__unused id vc) {
    gEnsureAttempts++;
}

extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) {
    return NO;
}

extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:
        @"injected=NO\\nmode=disabled; entrypoint is Settings long-press only\\nattempts=%lu",
        (unsigned long)gEnsureAttempts];
}
