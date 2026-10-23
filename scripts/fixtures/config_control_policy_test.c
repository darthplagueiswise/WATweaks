#include "WAGRConfigControlPolicy.h"
#include "WAGRConfigControlCatalog.h"
#include "WAGREligibilityPolicy.h"
#include <assert.h>
int main(void) {
    assert(WAGRConfigControlSelection(false, false) == 0);
    assert(WAGRConfigControlSelection(true, false) == 1);
    assert(WAGRConfigControlSelection(true, true) == 2);
    assert(WAGRConfigControlMutationAllowed(0, true));
    assert(!WAGRConfigControlMutationAllowed(1, true));
    assert(!WAGRConfigControlMutationAllowed(2, true));
    assert(WAGRConfigControlMutationAllowed(1, false));
    assert(WAGRConfigControlMutationAllowed(2, false));
    assert(!WAGRConfigControlMutationAllowed(-1, false));
    assert(!WAGRConfigControlMutationAllowed(3, false));
    assert(WAGRConfigControlOutcome(false, false) == WAGRRuntimeOverrideRejected);
    assert(WAGRConfigControlOutcome(false, true) == WAGRRuntimeOverrideRejected);
    assert(WAGRConfigControlOutcome(true, false) == WAGRRuntimeOverridePending);
    assert(WAGRConfigControlOutcome(true, true) == WAGRRuntimeOverrideInstalled);
    assert(WAGRConfigControlCatalogBuildMatches("26.40.10", "1086609742"));
    assert(!WAGRConfigControlCatalogBuildMatches("26.41.1", "1086609742"));
    assert(!WAGRConfigControlCatalogBuildMatches("26.40.10", "0"));
    for (size_t i = 0; i < WAGRConfigControlCount(); ++i) {
        const WAGRConfigControlDefinition *d = WAGRConfigControlAt(i);
        assert(d && d->selector && d->title && d->category && d->image);
        assert(WAGRConfigControlFind(d->selector) == d);
        assert(!WAGREligibilityOverrideIsProtectedCString("WAABProperties", d->selector));
        for (size_t j = 0; j < i; ++j)
            assert(strcmp(d->selector, WAGRConfigControlAt(j)->selector));
    }
    assert(WAGRConfigControlFind("enable_www_sessionbased_mc_sync"));
    assert(WAGRConfigControlFind("dogfooding_nudge_settings_entrypoint_enabled"));
    assert(WAGRConfigControlFind("ios_internal_rage_shake_enabled"));
    assert(!WAGRConfigControlFind("isInternalUser"));
    assert(!WAGRConfigControlFind("isMetaEmployeeOrInternalTester"));
    assert(!WAGRConfigControlFind("not_a_native_selector"));
    assert(!WAGRConfigControlAt(WAGRConfigControlCount()));
    assert(!WAGREligibilityOverrideIsProtectedCString("WAABProperties", "employees_split_thread_fix_enabled"));
    assert(WAGREligibilityOverrideIsProtectedCString("Other", "is_employee_account"));
    return 0;
}
