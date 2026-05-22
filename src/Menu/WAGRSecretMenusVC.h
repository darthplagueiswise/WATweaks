// WAGRSecretMenusVC.h
// ─────────────────────────────────────────────────────────────────────────────
// Control panel for the "make WhatsApp believe we're internal/Aura" path.
//
// Sections:
//   1. ATIVAR MASTER       — toggles that flip every related pref atomically.
//   2. DIAGNÓSTICO         — live state of each hook subsystem.
//   3. CONTROLLERS DEBUG   — informational list of the ~32 Debug VCs found
//                            in the Mach-O. No tap actions; instantiating
//                            them directly traps in Swift teardown.
//   4. COMO USAR           — recommended sequence.
//
// The earlier version of this file directly instantiated WhatsApp's hidden
// Debug VCs and crashed on dismissal. The new model: flip the upstream
// gate and let WhatsApp render the same screens through its native path.
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
