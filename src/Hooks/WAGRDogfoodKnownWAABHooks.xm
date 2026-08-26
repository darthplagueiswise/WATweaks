// WAGRDogfoodKnownWAABHooks.xm
// Compatibility shim only. WAABProperties values are owned by
// WAGRRuntimeValueStore, the same store used by ABProperties Browser and the
// canonical feature submenus. A second Logos hook layer here would reintroduce
// conflicting state/precedence for the same selectors.

#import <Foundation/Foundation.h>
#import "../Runtime/WAGRRuntimeValueStore.h"

static NSUInteger gWAGRKnownWAABLastReinstalled = 0;

extern "C" void WAGRDogfoodKnownWAABEnsureInstalled(void) {
    gWAGRKnownWAABLastReinstalled = WAGRRuntimeValueReinstallPersistedHooks();
}

extern "C" NSString *WAGRDogfoodKnownWAABDiagnosticText(void) {
    NSUInteger waabOverrides = 0;
    NSUInteger installed = 0;
    for (NSDictionary *spec in WAGRRuntimeValueAllOverrideSpecs()) {
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        BOOL meta = [spec[@"meta"] boolValue];
        if (![className containsString:@"WAABProperties"] &&
            ![className containsString:@"ABProperties"]) continue;
        waabOverrides++;
        if (WAGRRuntimeValueHookIsInstalled(className, selector, meta)) installed++;
    }
    return [NSString stringWithFormat:
        @"owner=RuntimeValueStore\nparallelLogosLayer=NO\nwaabOverrides=%lu\ninstalled=%lu\nlastReinstalled=%lu",
        (unsigned long)waabOverrides,
        (unsigned long)installed,
        (unsigned long)gWAGRKnownWAABLastReinstalled];
}

__attribute__((constructor))
static void WAGRDogfoodKnownWAABCtor(void) {
    // RuntimeValueStore already restores exact persisted hooks. Do not install a
    // competing WAABProperties hook table at launch.
}
