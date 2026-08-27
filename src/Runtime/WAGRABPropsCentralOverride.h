#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installs the four typed WAProperties choke-point hooks used by native ABProps
/// evaluation. Safe to call repeatedly; returns YES when at least the BOOL hook
/// is installed and the central overlay is usable.
BOOL WAGRABPropsCentralEnsureInstalled(void);

/// Persists a WATweaks-only ABProp overlay. `code` is the decimal WA stable ID
/// used by WAProperties (for example 1777). Supported canonical types are:
/// bool, int, double, string.
BOOL WAGRABPropsCentralSetOverride(NSString *code, NSString *type, id value);

void WAGRABPropsCentralClearOverride(NSString *code);
NSUInteger WAGRABPropsCentralClearAll(void);
BOOL WAGRABPropsCentralHasOverride(NSString *code);
id _Nullable WAGRABPropsCentralOverride(NSString *code);
NSDictionary<NSString *, NSDictionary *> *WAGRABPropsCentralAllOverrides(void);
NSString *WAGRABPropsCentralDiagnostic(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
