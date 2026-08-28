#import <Foundation/Foundation.h>

// Intentionally retired.
//
// The old compatibility layer independently replaced the same three release
// stubs as WAGRABPropsReleaseNativeLinkage:
//   +[WAMobileConfigABPropsOverridesSync syncABPropsOverridesToMCWithUserContext:]
//   +[WAMobileConfigABPropsOverridesSync overriddenStableIdsWithUserContext:]
//   -[WADebugViewController resetAllOverriddenABProps]
//
// Keeping two constructors racing to replace those IMPs made the effective
// pipeline dependent on load timing and allowed the shallow tracked-registry
// bridge to overwrite the native StartupConfigs/manager linkage.  The unified
// release linkage is now the sole owner of those disabled surfaces.
//
// This translation unit remains in the tree so historical references and
// wildcard source discovery do not break, but it deliberately installs no
// constructor and no hooks.

BOOL WAGRABPropsLegacyDisabledSurfaceCompatibilityIsRetired(void) {
    return YES;
}
