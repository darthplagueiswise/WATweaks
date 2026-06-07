#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void WAGRLogAppend(NSString *message);
void WAGRLogAppendF(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
NSString *WAGRLogSnapshot(void);
void WAGRLogClear(void);

#ifdef __cplusplus
}
#endif
