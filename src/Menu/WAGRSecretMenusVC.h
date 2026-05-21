// WAGRSecretMenusVC.h
// ─────────────────────────────────────────────────────────────────────────────
// Lists the ~25 WhatsApp debug view controllers that ship in the binary but
// are not surfaced anywhere in the standard UI. Tapping a row tries to
// instantiate the controller through every known init signature (plain
// `-init`, `-initWithUserContext:`, `-initAsModalWithUserContext:`,
// `-initWithStyle:`, `-initWithNibName:bundle:`) and presents whichever
// init returns a non-nil instance.
//
// The class roster is data-only and was sourced from static analysis of
// the WhatsApp 26.19.10 main binary (__objc_classlist walk filtered by
// Debug/Internal/Pancake/Diagnostic substrings).
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRSecretMenusVC : UITableViewController
- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
