#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Stable UI classifier for Runtime Avançado / Runtime Gates.
/// This is intentionally string-only: no class scan, no startup work, no resource dependency.
NSString *WAGRRuntimePrefixForName(NSString *name);
NSString *WAGRRuntimeSubcategoryForName(NSString *name);
NSString *WAGRRuntimeSectionForName(NSString *name);
NSString *WAGRRuntimeSectionForSelector(NSString *selectorName, NSString *className);

#ifdef __cplusplus
}
#endif
