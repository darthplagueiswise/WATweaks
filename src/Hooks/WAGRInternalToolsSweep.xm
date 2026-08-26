// WAGRInternalToolsSweep.xm
// Retired compatibility surface. Internal/debug/dogfood selectors are controlled
// explicitly by the canonical feature submenu or ABProperties Browser. Broad
// selector-name discovery is intentionally not a state owner anymore.

#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"

static void WAGRInternalToolsClearLegacyState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:WA_PREF_INTERNAL_TOOLS_SWEEP_BACKUP];
    [defaults synchronize];
}

extern "C" NSUInteger WAGRInternalToolsSweepSetEnabled(BOOL enabled) {
    (void)enabled;
    WAGRInternalToolsClearLegacyState();
    return 0;
}

extern "C" NSString *WAGRInternalToolsSweepDiagnosticText(void) {
    return @"retired=YES\nparallelBackup=NO\nbroadNameSweep=NO\nowner=GateStore/RuntimeValueStore exact targets";
}

__attribute__((constructor))
static void WAGRInternalToolsSweepCtor(void) {
    @autoreleasepool { WAGRInternalToolsClearLegacyState(); }
}
