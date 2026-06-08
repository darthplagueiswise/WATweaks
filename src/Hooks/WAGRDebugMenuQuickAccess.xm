// WAGRDebugMenuQuickAccess.xm
// Disabled intentionally: WATweaks must not mutate WhatsApp WADebugViewController UI.

#import <Foundation/Foundation.h>

extern "C" void WAGRDebugMenuQuickAccessEnsureInstalled(void) {}

extern "C" NSString *WAGRDebugMenuQuickAccessDiagnosticText(void) {
    return @"disabled; no WADebugViewController nav/button injection";
}
