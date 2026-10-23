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
    // IPA-confirmed feature controls, not account identity getters. The old
    // substring match incorrectly made these ordinary WAAB experiments read-only.
    if (className && strcmp(className, "WAABProperties") == 0 && selectorName &&
        (strcmp(selectorName, "give_dogfooders_task_id_for_bug_reporting") == 0 ||
         strcmp(selectorName, "employees_split_thread_fix_enabled") == 0 ||
         strcmp(selectorName, "ios_contact_suggestions_internal_tool_exclude_employees_enabled") == 0)) return false;
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
