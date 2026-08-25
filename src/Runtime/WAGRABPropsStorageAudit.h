#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Read-only comparison of the live preference domain used by ABProps against
/// the physical AppGroup preference files. No synchronize/write is performed.
NSDictionary<NSString *, id> *WAGRABPropsStorageAudit(void);
NSString *WAGRABPropsStorageAuditText(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
