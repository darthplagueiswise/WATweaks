#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Stable WATweaks replacement for WADebugViewController section 0 / row 0.
/// It does not touch WhatsApp's private WATableSection/WATableRow model; the
/// native Developer Menu datasource hook opens this controller when the AB Props
/// yellow card row is tapped.
@interface WAGRABPropsRootVC : UITableViewController
@end

NS_ASSUME_NONNULL_END
