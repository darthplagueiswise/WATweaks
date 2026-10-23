#pragma once
#include <stdbool.h>

typedef enum {
    WAGRRuntimeOverrideRejected = 0,
    WAGRRuntimeOverridePending,
    WAGRRuntimeOverrideInstalled
} WAGRRuntimeOverrideOutcome;

static inline int WAGRConfigControlSelection(bool hasOverride, bool forced) {
    return hasOverride ? (forced ? 2 : 1) : 0;
}

static inline bool WAGRConfigControlMutationAllowed(int selection, bool otherLayerHasOverride) {
    return selection >= 0 && selection <= 2 &&
        (selection == 0 || !otherLayerHasOverride);
}

static inline WAGRRuntimeOverrideOutcome WAGRConfigControlOutcome(bool persisted, bool installed) {
    return !persisted ? WAGRRuntimeOverrideRejected :
        (installed ? WAGRRuntimeOverrideInstalled : WAGRRuntimeOverridePending);
}
