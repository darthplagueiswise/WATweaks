#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL WAGRFLEXIsAvailable(void);
BOOL WAGRFLEXShowExplorer(NSString **errorText);
BOOL WAGRFLEXExploreObject(id object, NSString **errorText);
NSString *WAGRFLEXDiagnosticText(void);

#ifdef __cplusplus
}
#endif
