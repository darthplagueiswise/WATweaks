#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const kWAGRRuntimeValueOverridesKey;

NSString *WAGRRuntimeValueUID(NSString *className,
                               NSString *selectorName,
                               BOOL isClassMethod);
NSString * _Nullable WAGRRuntimeValueTypeName(NSString *typeCode);
BOOL WAGRRuntimeValueTypeIsSupported(NSString *typeCode);
BOOL WAGRRuntimeValueTypeIsBoolean(NSString *typeCode);
BOOL WAGRRuntimeValueTypeIsSignedInteger(NSString *typeCode);
BOOL WAGRRuntimeValueTypeIsUnsignedInteger(NSString *typeCode);
BOOL WAGRRuntimeValueTypeIsFloatingPoint(NSString *typeCode);
BOOL WAGRRuntimeValueTypeIsObject(NSString *typeCode);

BOOL WAGRRuntimeValueHasOverride(NSString *className,
                                 NSString *selectorName,
                                 BOOL isClassMethod);
id _Nullable WAGRRuntimeValueOverride(NSString *className,
                                      NSString *selectorName,
                                      BOOL isClassMethod);
void WAGRRuntimeValueSetOverride(NSString *className,
                                 NSString *selectorName,
                                 BOOL isClassMethod,
                                 NSString *typeCode,
                                 id value);
void WAGRRuntimeValueClearOverride(NSString *className,
                                   NSString *selectorName,
                                   BOOL isClassMethod);
NSArray<NSDictionary<NSString *, id> *> *WAGRRuntimeValueAllOverrideSpecs(void);

BOOL WAGRRuntimeValueInstallHook(NSString *className,
                                 NSString *selectorName,
                                 BOOL isClassMethod,
                                 NSString *typeCode);
BOOL WAGRRuntimeValueHookIsInstalled(NSString *className,
                                     NSString *selectorName,
                                     BOOL isClassMethod);
NSUInteger WAGRRuntimeValueReinstallPersistedHooks(void);

/// Reads the effective value currently seen by the app. If the caller does not
/// have an instance receiver, a weak receiver captured by the exact installed
/// hook is used when available.
NSString *WAGRRuntimeValueRead(NSString *className,
                               NSString *selectorName,
                               BOOL isClassMethod,
                               id _Nullable instance,
                               id _Nullable * _Nullable rawValue);

/// Reads through the original IMP, bypassing an installed WATweaks override.
/// This is what "Usar original" and diagnostics should display when an exact
/// receiver is available/captured.
NSString *WAGRRuntimeValueReadOriginal(NSString *className,
                                       NSString *selectorName,
                                       BOOL isClassMethod,
                                       id _Nullable instance,
                                       id _Nullable * _Nullable rawValue);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END