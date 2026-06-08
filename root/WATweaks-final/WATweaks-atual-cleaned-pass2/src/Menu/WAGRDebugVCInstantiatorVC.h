// WAGRDebugVCInstantiatorVC.h
// Safe Debug VC lab.
//
// This screen intentionally does NOT instantiate hidden WhatsApp Debug VCs
// directly. Several Swift debug controllers trap on dismissal when created
// outside WhatsApp's native dependency graph. The lab is for availability and
// initializer diagnostics, plus the one safe native launcher path for the
// top-level WADebugViewController.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRDebugVCInstantiatorVC : UITableViewController
- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
