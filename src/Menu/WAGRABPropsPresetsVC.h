#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reconstructs the 13 "Set ABProps to ..." presets compiled into WhatsApp
/// 26.33. Values are resolved back to stable IDs at runtime before the native
/// StartupConfigs writer is allowed to change anything.
@interface WAGRABPropsPresetsVC : UITableViewController
- (instancetype)initWithUserContext:(id _Nullable)userContext;
@end

NS_ASSUME_NONNULL_END
