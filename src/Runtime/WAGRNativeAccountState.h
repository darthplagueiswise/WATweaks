#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
/// Reads native account/internal gates. Unavailable is distinct from false.
NSDictionary<NSString *, id> *WAGRNativeAccountStateDocument(id context);
#ifdef __cplusplus
}
#endif
