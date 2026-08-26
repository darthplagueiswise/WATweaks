#import <Foundation/Foundation.h>

/*
 * Historical compatibility unit.
 *
 * An older investigation stage installed a delayed showExportMenu: replacement
 * here and forced the MobileConfig screen back to a read-only policy. That is no
 * longer valid: the current code resolves mc_overrides identity through the
 * account-scoped FBMobileConfigUserSessionContextManager and merges only exact
 * (configStableId, parameterIndex) pairs into the path returned by
 * getOverridesTablePath, preserving all unrelated rows.
 *
 * Keep this translation unit so older build manifests remain stable, but do not
 * swizzle WAGRMobileConfigExportVC or replace the functional ABProps/preset menu.
 */

__attribute__((constructor))
static void WAGRMobileConfigValidatedExportPolicyCtor(void) {
    @autoreleasepool {
        // Intentionally no runtime mutation.
    }
}
