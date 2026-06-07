#import <Foundation/Foundation.h>

static BOOL gWAGRDebugMenuInstrumentationInstalled = NO;
extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void) { gWAGRDebugMenuInstrumentationInstalled = YES; }
extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    return [NSString stringWithFormat:@"DebugMenuInstrumentation installed=%@\nowner=compat-no-duplicate", gWAGRDebugMenuInstrumentationInstalled ? @"YES" : @"NO"];
}
__attribute__((constructor)) static void WAGRDebugMenuInstrumentationCtor(void) { WAGRDebugMenuInstrumentationEnsureInstalled(); }
