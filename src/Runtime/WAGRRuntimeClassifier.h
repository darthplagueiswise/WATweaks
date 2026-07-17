#pragma once
#import <Foundation/Foundation.h>
#import "WAGRSurface.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Stable compatibility facade for Runtime Avançado / Runtime Gates.
/// WAGRSurface.h is intentionally re-exported here because the live runtime
/// family/subcategory functions are the source of truth used by all callers.
NSString *WAGRRuntimePrefixForName(NSString *name);
NSString *WAGRRuntimeSubcategoryForName(NSString *name);
NSString *WAGRRuntimeSectionForName(NSString *name);
NSString *WAGRRuntimeSectionForSelector(NSString *selectorName, NSString *className);

#ifdef __cplusplus
}
#endif