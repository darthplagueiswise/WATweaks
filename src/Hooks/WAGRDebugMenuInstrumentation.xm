// WAGRDebugMenuInstrumentation.xm
// Disabled: no hooks inside WhatsApp WADebugViewController / Developer menu.
// Native Developer menu access is controlled only by gate hooks in WAGRNativeDevMenuHooks.xm.

#import <Foundation/Foundation.h>

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void) {}

extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    return @"disabled; no Developer menu instrumentation or UI mutation";
}
