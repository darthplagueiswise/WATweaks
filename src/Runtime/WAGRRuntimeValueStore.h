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
NSUInteger WAGRRuntimeValueReinstallPersistedHooks(void);

NSString *WAGRRuntimeValueRead(NSString *className,
                               NSString *selectorName,
                               BOOL isClassMethod,
                               id _Nullable instance,
                               id _Nullable * _Nullable rawValue);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
