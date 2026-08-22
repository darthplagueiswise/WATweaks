#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

id WAGRCurrentUserContext(void);
void WAGRRememberUserContext(id ctx, NSString *source);
NSString *WAGRCurrentUserContextDiagnostic(void);

#ifdef __cplusplus
}
#endif
