#ifndef WAGRMobileConfigFetchPolicy_h
#define WAGRMobileConfigFetchPolicy_h
#include <stdbool.h>
#include <string.h>

typedef enum {
    WAGRMCFetchRouteUnavailable = 0,
    WAGRMCFetchRouteLegacyBool,
    WAGRMCFetchRouteBoolStack
} WAGRMCFetchRoute;

/* Native 26.40 callers pass -1; LastFetchStore labels it "unset".
 * Let WhatsApp choose its backend instead of selecting erlang(0) or www(1). */
enum { WAGRMCFetchNativeStackAutomatic = -1, WAGRMCFetchUserSessionUnitType = 2 };

static inline WAGRMCFetchRoute WAGRMCFetchSelectRoute(const char *modern, const char *legacy) {
    if (modern && strcmp(modern, "v24@0:8B16i20") == 0) return WAGRMCFetchRouteBoolStack;
    if (legacy && (strcmp(legacy, "v20@0:8B16") == 0 ||
                   strcmp(legacy, "v20@0:8c16") == 0 ||
                   strcmp(legacy, "v20@0:8C16") == 0)) return WAGRMCFetchRouteLegacyBool;
    return WAGRMCFetchRouteUnavailable;
}

static inline bool WAGRMCFetchMarkerMatches(bool requestActive, bool samePreferencesStore,
                                            int expectedUnitType, int observedUnitType,
                                            bool sameNonemptyUnitId) {
    return requestActive && samePreferencesStore &&
        expectedUnitType == WAGRMCFetchUserSessionUnitType &&
        observedUnitType == expectedUnitType && sameNonemptyUnitId;
}
#endif
