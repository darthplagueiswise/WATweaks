// WhatsApp 26.40.10 account eligibility is server/account-owned.
// Keep the historical API for callers, but expose diagnostics only.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSArray<NSString *> *WAGREligibilityCandidateClasses(void) {
    return @[
        @"WAAccountEligibility",
        @"_TtC20WAAccountEligibility13PAAGatekeeper",
        @"_TtC20WAAccountEligibility14PMTAGatekeeper",
    ];
}

extern "C" void WAGRAccountEligibilityEnsureHooksInstalled(void) {
    // Deliberately no-op. Local code must not synthesize server eligibility.
}

extern "C" NSString *WAGRAccountEligibilityDiagnostic(void) {
    NSMutableArray<NSString *> *loaded = [NSMutableArray array];
    for (NSString *className in WAGREligibilityCandidateClasses()) {
        if (NSClassFromString(className)) [loaded addObject:className];
    }
    return [NSString stringWithFormat:
        @"mode=read-only\ninstalled=0\neligibilityOwner=server/account\nclasses found=%@",
        loaded.count ? [loaded componentsJoinedByString:@", "] : @"none"];
}

__attribute__((constructor))
static void WAGRAccountEligibilityCtor(void) {
    // No startup hooks.
}
