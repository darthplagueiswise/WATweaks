// WAGateStore.h — migrated from WAGRGateStore.h (aggressive WAGRGate* → WAGate*)
// Single source of truth for gate overrides.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const kWAGateStorageWipedMarkerV2;
extern NSString * const kWATGateOverrideIndexKey;
extern NSString * const kWATGateHookIndexKey;

NSString *WAGateCanonicalKey(NSString *key);
NSString *WAGateDisplayKey(NSString *key);

BOOL WAGateIsSet(NSString *key);
BOOL WAGateGet(NSString *key);
void WAGateSet(NSString *key, BOOL value);
void WAGateClear(NSString *key);

NSArray<NSString *> *WAGateAllOverrides(void);
NSUInteger WAGateClearAll(void);

void WAGateRememberHook(NSString *className, NSString *selectorName, BOOL isClassMethod);
void WAGateForgetHook(NSString *className, NSString *selectorName, BOOL isClassMethod);
NSArray<NSDictionary<NSString *, id> *> *WAGatePersistedHookSpecs(void);

void WAGateWipeLegacyStorageIfNeeded(void);
NSString *WAGateStoreDiagnostic(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END