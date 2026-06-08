// WAGRDebugMenuQuickAccess.xm
// Disabled: WATweaks must not mutate WADebugViewController UI.

#import <Foundation/Foundation.h>

extern "C" void WAGRDebugMenuQuickAccessEnsureInstalled(void) {}

extern "C" NSString *WAGRDebugMenuQuickAccessDiagnosticText(void) {
    return @"disabled; no WADebugViewController nav/button injection";
}
