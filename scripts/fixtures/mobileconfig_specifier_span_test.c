#include "WAGRMobileConfigSpecifierSpan.h"
#include <assert.h>
#include <limits.h>
#include <string.h>

int main(void) {
    /* Native 26.40 samples: holes are real, flags must remain intact. */
    uint64_t entries[] = {0, UINT64_C(0x81000000000000),
                          UINT64_C(0x2081000700000005)};
    WAGRMCSpecifierSpan span = {0x1000, 3};
    assert(WAGRMCSpecifierSpanByteLength(span) == sizeof(entries));
    assert(WAGRMCSpecifierSnapshotValue(entries, sizeof(entries), 0) == 0);
    assert(WAGRMCSpecifierSnapshotValue(entries, sizeof(entries), 1) == entries[1]);
    assert(WAGRMCSpecifierSnapshotValue(entries, sizeof(entries), 2) == entries[2]);
    assert(WAGRMCSpecifierSnapshotValue(entries, sizeof(entries), 3) == 0);
    assert(WAGRMCSpecifierSnapshotValue(entries, sizeof(entries), UINT64_MAX) == 0);
    assert(WAGRMCSpecifierSnapshotValue(NULL, sizeof(entries), 1) == 0);
    assert(WAGRMCSpecifierSnapshotValue(entries, sizeof(entries) - 1, 2) == 0);
    span.count = 38805;
    assert(WAGRMCSpecifierSpanByteLength(span) == 310440);
    span.count = 0;
    assert(WAGRMCSpecifierSpanByteLength(span) == 0);
    span.count = UINT64_MAX;
    assert(WAGRMCSpecifierSpanByteLength(span) == 0);
    span.count = 3;
    span.entries = 0;
    assert(WAGRMCSpecifierSpanByteLength(span) == 0);
    span.entries = 0x1001;
    assert(WAGRMCSpecifierSpanByteLength(span) == 0);
    span.entries = UINT64_MAX - 7;
    assert(WAGRMCSpecifierSpanByteLength(span) == 0);
    return 0;
}
