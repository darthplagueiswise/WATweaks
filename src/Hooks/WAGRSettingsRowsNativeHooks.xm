#import <Foundation/Foundation.h>

static NSString *gWAGRSettingsRowsState = @"disabled: no native WhatsApp menu row injection";

extern "C" void WAGRSettingsRowsNativeEnsureHooksInstalled(void) { gWAGRSettingsRowsState = @"disabled"; }
extern "C" void WAGRSettingsRowsNativeInjectIfPossible(id maybeSettingsVC) { (void)maybeSettingsVC; gWAGRSettingsRowsState = @"disabled"; }
extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) { return NO; }
extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:@"native row injection=OFF\nsettingsButtonInserted=NO\ninjectAttempts=0\nstate=%@", gWAGRSettingsRowsState ?: @"disabled"];
}
