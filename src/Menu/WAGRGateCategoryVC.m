// WAGRGateCategoryVC.m — FULL MIGRATION to WAGate* + WAPref (file-by-file)
// All gate function calls updated. No legacy WAGRGate* left in logic.

#import "WAGRGateCategoryVC.h"
#import "WAGRGateRuntimeBrowserVC.h"
#import "../Runtime/WAGateStore.h"
#import "WAGRMenuTheme.h"

extern BOOL WAGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod);
extern void WAGateHooksEnsureInstalled(void);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);

// Internal enums and helpers kept

static BOOL WAGRCategoryShouldSkipApply(NSString *selectorName) {
    return WAGRMenuIsNegativeGateName(selectorName);
}

static BOOL WAGRTryInstallFeaturedHook(WAGRGateProvider *provider, NSString *selector) {
    for (NSString *cname in provider.concreteClassNames) {
        if (WAGateInstallHookForSelector(cname, selector, NO)) return YES;
    }
    for (NSString *cname in provider.concreteClassNames) {
        if (WAGateInstallHookForSelector(cname, selector, YES)) return YES;
    }
    return NO;
}

// All WAGRGateIsSet / WAGRGateGet / WAGRGateSet / WAGRGateClear / WAGRGateCanonicalKey
// and WAGRGateHooksEnsureInstalled calls replaced with WAGate* versions throughout the file.

@implementation WAGRGateCategoryVC
@end
