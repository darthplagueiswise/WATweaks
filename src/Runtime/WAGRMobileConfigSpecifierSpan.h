#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Verified in SharedModules 26.40.10: const {uint64_t *entries, size_t count}.
 * The limit below is an allocation safety bound, never a stable-ID domain. */
typedef struct {
    uint64_t entries;
    uint64_t count;
} WAGRMCSpecifierSpan;

static inline size_t WAGRMCSpecifierSpanByteLength(WAGRMCSpecifierSpan span) {
    if (!span.entries || (span.entries & 7) || !span.count ||
        span.count > (UINT64_C(1) << 20) || span.count > SIZE_MAX / 8) return 0;
    size_t bytes = (size_t)span.count * 8;
    if (span.entries > UINT64_MAX - bytes) return 0;
    return bytes;
}

static inline uint64_t WAGRMCSpecifierSnapshotValue(const void *bytes, size_t length,
                                                    uint64_t stableID) {
    if (!bytes || length % 8 || stableID >= length / 8) return 0;
    uint64_t value = 0;
    memcpy(&value, (const unsigned char *)bytes + (size_t)stableID * 8, 8);
    return value;
}
