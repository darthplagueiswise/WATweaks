// WAGRGateStore.h — single source of truth for gate overrides.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const kWAGRStorageWipedMarkerV2;
extern NSString * const kWATGateOverrideIndexKey;
extern NSString * const kWATGateHookIndexKey;

NSString *WATCanonicalPreferenceKey(NSString *domain, NSString *target);
NSString *WAGRGateCanonicalKey(NSString *key);
NSString *WAGRGateDisplayKey(NSString *key);

BOOL WAGRGateIsSet(NSString *key);
BOOL WAGRGateGet(NSString *key);
void WAGRGateSet(NSString *key, BOOL value);
void WAGRGateClear(NSString *key);
NSArray<NSString *> *WAGRGateAllOverrides(void);
NSUInteger WAGRGateClearAll(void);

void WAGRGateRememberHook(NSString *className, NSString *selectorName, BOOL isClassMethod);
void WAGRGateForgetHook(NSString *className, NSString *selectorName, BOOL isClassMethod);
NSArray<NSDictionary<NSString *, id> *> *WAGRGatePersistedHookSpecs(void);

void WAGRWipeLegacyStorageIfNeeded(void);
NSString *WAGRGateStoreDiagnostic(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
