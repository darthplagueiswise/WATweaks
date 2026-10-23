#pragma once
#include <stdbool.h>
#include <string.h>

/* 0 = unknown, 1 = SharedModules, 2 = WhatsApp. Match the executable name. */
static inline int WAGRWAABCatalogImageCString(const char *path) {
    if (!path || !path[0]) return 0;
    const char *last = strrchr(path, '/');
    const char *name = last ? last + 1 : path;
    if (strcmp(name, "SharedModules") == 0) return 1;
    if (strcmp(name, "WhatsApp") == 0) return 2;
    return 0;
}

static inline bool WAGRWAABCatalogMayUseImageCString(const char *source, int candidateImage) {
    int known = WAGRWAABCatalogImageCString(source);
    return known == 0 || known == candidateImage;
}

static inline bool WAGRWAABCatalogBuildMatchesCString(const char *catalogVersion,
                                                       const char *catalogBuild,
                                                       const char *runningVersion,
                                                       const char *runningBuild) {
    return catalogVersion && catalogBuild && runningVersion && runningBuild &&
           catalogVersion[0] && catalogBuild[0] && runningVersion[0] && runningBuild[0] &&
           strcmp(catalogVersion, runningVersion) == 0 &&
           strcmp(catalogBuild, runningBuild) == 0;
}
