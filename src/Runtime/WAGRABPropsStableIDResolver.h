#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Resolves the decimal WA ABProp stable ID directly from the currently loaded
/// ARM64 getter implementation. Current WhatsApp builds commonly materialize
/// the key as ADRP/ADD -> NSConstantString in __cfstring -> decimal C string;
/// older/direct C-string forms remain supported as a fallback.
NSString * _Nullable WAGRABPropsStableIDForTarget(NSString *className,
                                                   NSString *selectorName,
                                                   BOOL classMethod);

/// Runtime-only counters used by the Debug diagnostics. No scan is performed by
/// this call; the values describe resolver work already requested by browsers.
NSDictionary<NSString *, NSNumber *> *WAGRABPropsStableIDResolverStats(void);

/// Clears only the resolver's in-memory cache/counters. It does not change any
/// WhatsApp or WATweaks persisted override.
void WAGRABPropsStableIDResolverResetCache(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
