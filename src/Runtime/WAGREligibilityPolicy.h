#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

static inline char WAGREligibilityASCIILower(char value) {
    return value >= 'A' && value <= 'Z' ? (char)(value + ('a' - 'A')) : value;
}

static inline bool WAGREligibilityContainsCString(const char *value, const char *needle) {
    if (!value || !needle || !needle[0]) return false;
    for (const char *start = value; *start; start++) {
        const char *left = start;
        const char *right = needle;
        while (*left && *right && WAGREligibilityASCIILower(*left) == WAGREligibilityASCIILower(*right)) {
            left++;
            right++;
        }
        if (!*right) return true;
    }
    return false;
}

/// Server/account eligibility must never be replaced by a local override.
static inline bool WAGREligibilityOverrideIsProtectedCString(const char *className,
                                                              const char *selectorName) {
    if (WAGREligibilityContainsCString(className, "eligibility")) return true;
    if (selectorName && strcmp(selectorName, "adm") == 0) return true;
    return WAGREligibilityContainsCString(selectorName, "eligible") ||
           WAGREligibilityContainsCString(selectorName, "eligibility") ||
           WAGREligibilityContainsCString(selectorName, "internaluser") ||
           WAGREligibilityContainsCString(selectorName, "internal_tester") ||
           WAGREligibilityContainsCString(selectorName, "is_internal") ||
           WAGREligibilityContainsCString(selectorName, "employee") ||
           WAGREligibilityContainsCString(selectorName, "dogfooder") ||
           WAGREligibilityContainsCString(selectorName, "serverpropsdisableexperimental") ||
           WAGREligibilityContainsCString(selectorName, "graphqlemployeec1disabled");
}
