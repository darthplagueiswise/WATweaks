#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* A compatible return ABI does not make a no-argument method a getter. */
static inline bool WAGRRuntimeSelectorHasMethodFamily(const char *name, const char *family) {
    size_t length = strlen(family);
    return strncmp(name, family, length) == 0 &&
        !(name[length] >= 'a' && name[length] <= 'z');
}

static inline bool WAGRRuntimeSelectorIsSafeGetterCString(const char *name) {
    if (!name || !name[0] || strchr(name, ':')) return false;
    if (strncmp(name, ".cxx_", 5) == 0) return false;
    const char *families[] = { "alloc", "init", "new", "copy", "mutableCopy" };
    for (size_t i = 0; i < sizeof(families) / sizeof(families[0]); i++) {
        if (WAGRRuntimeSelectorHasMethodFamily(name, families[i])) return false;
    }
    const char *blocked[] = {
        "dealloc", "finalize", "load", "initialize",
        "retain", "release", "autorelease", "retainCount", "zone",
        "class", "superclass", "self", "hash", "description", "debugDescription",
        "isProxy", "isFault", "observationInfo",
        /* Supported-ABI actions observed in the supplied IPA. */
        "start", "startIfNeeded", "startNotifier", "startReading", "startWriting",
        "stopAndReconnectWithCurrentSessionID", "resetDatabase",
        "stop", "stopNotifier", "reset", "invalidate", "cancel", "resume", "suspend"
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if (strcmp(name, blocked[i]) == 0) return false;
    }
    return true;
}

static inline bool WAGRRuntimePathIsWithinBundleCString(const char *path, const char *bundle) {
    if (!path || !bundle || !bundle[0]) return false;
    size_t length = strlen(bundle);
    while (length > 1 && bundle[length - 1] == '/') length--;
    return strncmp(path, bundle, length) == 0 &&
        (path[length] == '/' || path[length] == '\0');
}

/* Image membership follows the method IMP, including cross-image categories. */
static inline bool WAGRRuntimeMethodMatchesImageCString(const char *methodImage,
                                                         const char *requestedImage) {
    if (!requestedImage || !requestedImage[0]) return true;
    return methodImage && strcmp(methodImage, requestedImage) == 0;
}

/* Nested apps/extensions have separate processes. Skip hidden/localized data. */
static inline bool WAGRRuntimeBundledPathIsInspectableCString(const char *relativePath) {
    if (!relativePath || !relativePath[0] || relativePath[0] == '/') return false;
    for (const char *part = relativePath; part && part[0];) {
        const char *slash = strchr(part, '/');
        size_t length = slash ? (size_t)(slash - part) : strlen(part);
        if (!length || part[0] == '.' ||
            (length == 7 && strncmp(part, "PlugIns", length) == 0) ||
            (length >= 6 && strncmp(part + length - 6, ".appex", 6) == 0) ||
            (length >= 4 && strncmp(part + length - 4, ".app", 4) == 0) ||
            (length >= 6 && strncmp(part + length - 6, ".lproj", 6) == 0)) return false;
        part = slash ? slash + 1 : NULL;
    }
    return true;
}

static inline bool WAGRRuntimeFileIsMachOCString(const char *path) {
    if (!path || !path[0]) return false;
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    unsigned char magic[4] = {0};
    size_t length = fread(magic, 1, sizeof(magic), file);
    fclose(file);
    if (length != sizeof(magic)) return false;
    const unsigned char signatures[][4] = {
        {0xce, 0xfa, 0xed, 0xfe}, {0xcf, 0xfa, 0xed, 0xfe},
        {0xfe, 0xed, 0xfa, 0xce}, {0xfe, 0xed, 0xfa, 0xcf},
        {0xca, 0xfe, 0xba, 0xbe}, {0xca, 0xfe, 0xba, 0xbf},
        {0xbe, 0xba, 0xfe, 0xca}, {0xbf, 0xba, 0xfe, 0xca}
    };
    for (size_t i = 0; i < sizeof(signatures) / sizeof(signatures[0]); i++) {
        if (memcmp(magic, signatures[i], sizeof(magic)) == 0) return true;
    }
    return false;
}
