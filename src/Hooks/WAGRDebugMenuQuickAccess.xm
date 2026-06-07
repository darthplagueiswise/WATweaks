// WAGRDebugMenuQuickAccess.xm
//
// Disabled by design.
// WATweaks must not mutate WhatsApp's native WADebugViewController UI.
// Entrypoint is Settings long-press only.

#import <Foundation/Foundation.h>

extern "C" void WAGRDebugMenuQuickAccessEnsureInstalled(void) {
    // no-op
}

extern "C" NSString *WAGRDebugMenuQuickAccessDiagnosticText(void) {
    return @"disabled; no WADebugViewController nav/button injection";
}
