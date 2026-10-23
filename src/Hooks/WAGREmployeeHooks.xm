// WhatsApp 26.40.10 internal/employee state is server/account-owned.
// This compatibility API remains for callers, but deliberately installs no
// override hook and never expands local flags into eligibility.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *WAGRNativeEligibilityValue(Class cls, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return @"unavailable";
    char result[8] = {0};
    method_getReturnType(method, result, sizeof(result));
    if (result[0] != 'B' && result[0] != 'c') return @"ABI mismatch";
    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(cls, selector);
        return value ? @"YES" : @"NO";
    } @catch (__unused NSException *exception) {
        return @"exception";
    }
}

extern "C" void WAGRDogfoodEnsureHooksInstalled(void) {
    // Intentionally empty: the verified dogfood URL is the activation surface.
    // Native eligibility must remain the value returned by WhatsApp.
}

extern "C" NSString *WAGRDogfoodDiagnosticText(void) {
    Class serverProperties = objc_getClass("WAServerProperties");
    return [NSString stringWithFormat:
        @"mode=read-only\n"
         "eligibilityOwner=server/account\n"
         "localEligibilityHooks=NO\n"
         "WAServerProperties=%@\n"
         "isInternalUser=%@",
        serverProperties ? @"available" : @"unavailable",
        WAGRNativeEligibilityValue(serverProperties, @"isInternalUser")];
}

__attribute__((constructor))
static void WAGREmployeeHooksCtor(void) {
    // No startup hooks or account-eligibility mutation.
}
