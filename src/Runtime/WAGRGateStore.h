// WAGRGateStore.h — single source of truth for gate overrides.
// ─────────────────────────────────────────────────────────────────────────────
// Schema v3: all gate overrides live under watweak_gate_* and are tracked by
// an explicit index. Menus may pass legacy or display keys, but the store
// always canonicalizes before reading/writing.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const kWAGRStorageWipedMarkerV2;
extern NSString * const kWATGateOverrideIndexKey;

NSString *WATCanonicalPreferenceKey(NSString *domain, NSString *target);
NSString *WAGRGateCanonicalKey(NSString *key);
NSString *WAGRGateDisplayKey(NSString *key);

BOOL WAGRGateIsSet(NSString *key);
BOOL WAGRGateGet(NSString *key);
void WAGRGateSet(NSString *key, BOOL value);
void WAGRGateClear(NSString *key);

NSArray<NSString *> *WAGRGateAllOverrides(void);
NSUInteger WAGRGateClearAll(void);

void WAGRWipeLegacyStorageIfNeeded(void);
NSString *WAGRGateStoreDiagnostic(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
