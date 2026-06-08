// WAGRSettingsRowsNativeHooks.xm
// Disabled intentionally: no row/cell injection into WhatsApp Settings.
// Entry point is the guarded long-press installed from Tweak.x.

#import <Foundation/Foundation.h>

static NSUInteger gEnsureAttempts = 0;

extern "C" void WAGRSettingsRowsNativeEnsureHooksInstalled(void) { gEnsureAttempts++; }
extern "C" void WAGRSettingsRowsNativeInjectIfPossible(__unused id vc) { gEnsureAttempts++; }
extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) { return NO; }
extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:@"injected=NO\nmode=disabled; Settings long-press only\nattempts=%lu", (unsigned long)gEnsureAttempts];
}
