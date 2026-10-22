#include "WAGRMobileConfigFetchPolicy.h"
#include <assert.h>
int main(void) {
    /* Actual 26.40 metadata, old single-BOOL entrypoint, and incompatible ABIs. */
    assert(WAGRMCFetchSelectRoute("v24@0:8B16i20", 0) == WAGRMCFetchRouteBoolStack);
    assert(WAGRMCFetchSelectRoute("v24@0:8B16i20", "v20@0:8B16") == WAGRMCFetchRouteBoolStack);
    assert(WAGRMCFetchSelectRoute(0, "v20@0:8B16") == WAGRMCFetchRouteLegacyBool);
    assert(WAGRMCFetchSelectRoute("v24@0:8B16q20", "v20@0:8c16") == WAGRMCFetchRouteLegacyBool);
    assert(WAGRMCFetchSelectRoute("@24@0:8B16i20", "v20@0:8i16") == WAGRMCFetchRouteUnavailable);
    assert(WAGRMCFetchSelectRoute("v24@0:8B16I20", 0) == WAGRMCFetchRouteUnavailable);
    assert(WAGRMCFetchSelectRoute(0, 0) == WAGRMCFetchRouteUnavailable);
    assert(WAGRMCFetchNativeStackAutomatic == -1);
    /* Sessionless, other-account, or other-store markers cannot finish this request. */
    assert(WAGRMCFetchMarkerMatches(1, 1, 2, 2, 1));
    assert(!WAGRMCFetchMarkerMatches(0, 1, 2, 2, 1));
    assert(!WAGRMCFetchMarkerMatches(1, 0, 2, 2, 1));
    assert(!WAGRMCFetchMarkerMatches(1, 1, 2, 1, 1));
    assert(!WAGRMCFetchMarkerMatches(1, 1, 2, 3, 1));
    assert(!WAGRMCFetchMarkerMatches(1, 1, 2, 2, 0));
    assert(!WAGRMCFetchMarkerMatches(1, 1, 1, 1, 1));
    return 0;
}
