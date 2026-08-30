#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Portable, typed WAAB runtime snapshot. Export records every live getter and
/// its verified stable ID; import revalidates class/selector/stable-ID linkage
/// before using the native StartupConfigs override engine.
@interface WAGRABPropsConfigVC : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithUserContext:(id _Nullable)userContext;
@end

NS_ASSUME_NONNULL_END
