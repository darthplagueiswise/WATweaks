// WAGRGateStore.h — single source of truth for gate overrides.
// ─────────────────────────────────────────────────────────────────────────────
// Schema v2 (see WAGramPrefix.h for the long-form rationale).
//
//   key   = exact selector or flag name (e.g. "isInternalUser")
//   value = NSNumber BOOL (YES forces ON, NO forces OFF)
//   absent = no override
//
// The WAGRWipeLegacyStorage() function runs once at constructor time and
// drops every wagr.waab.* / wagr.override|... / wagr.observed* / legacy
// wagr.override.* key. After that, only the flat schema is in play.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Marker key (NSUserDefaults BOOL) used to ensure the legacy wipe runs once.
// Visible publicly so diagnostics can show whether the wipe already ran.
extern NSString * const kWAGRStorageWipedMarkerV2;
extern NSString * const kWATGateOverrideIndexKey;

NSString *WATCanonicalPreferenceKey(NSString *domain, NSString *target);
NSString *WAGRGateCanonicalKey(NSString *key);
NSString *WAGRGateDisplayKey(NSString *key);

// ── Gate override accessors (selector-name keys) ─────────────────────────────
// All four are nil-safe and synchronize at the end of any mutation.

/// YES iff an explicit override is stored for the gate `key` (independent of value).
BOOL WAGRGateIsSet(NSString *key);

/// Returns the stored override BOOL. NO if absent; check WAGRGateIsSet first.
BOOL WAGRGateGet(NSString *key);

/// Stores `value` for `key`. No-op for nil/empty key.
void WAGRGateSet(NSString *key, BOOL value);

/// Removes any stored override for `key`. No-op for nil/empty key.
void WAGRGateClear(NSString *key);

// ── Bulk operations ──────────────────────────────────────────────────────────
/// Returns a snapshot of every gate key currently overridden. Stable order
/// is not guaranteed; the array contains only selector names, not values.
NSArray<NSString *> *WAGRGateAllOverrides(void);

/// Removes every gate override (useful for the "reset overrides" menu item).
/// Returns the number of keys removed.
NSUInteger WAGRGateClearAll(void);

// ── Legacy migration / wipe ──────────────────────────────────────────────────
/// Idempotent. Runs on first launch of schema v2 and removes every legacy
/// override key. Records kWAGRStorageWipedMarkerV2 so subsequent launches
/// skip the wipe. Safe to call multiple times.
void WAGRWipeLegacyStorageIfNeeded(void);

/// Diagnostic summary: count of overrides, wipe marker state.
NSString *WAGRGateStoreDiagnostic(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
