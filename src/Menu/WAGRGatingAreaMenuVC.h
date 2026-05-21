// WAGRGatingAreaMenuVC.h
// ─────────────────────────────────────────────────────────────────────────────
// Data-driven menu that shows every catalog entry for a single area as a
// toggleable cell. One instance of this class is reused for every area;
// the area is supplied at init time and the cell content is generated
// from the WAGRGatingCatalog.
//
// This replaces the "scan-everything-and-show-anything" menu UX with a
// curated, semantically meaningful list that explains what each toggle does.
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import "WAGRGatingCatalog.h"

NS_ASSUME_NONNULL_BEGIN

@interface WAGRGatingAreaMenuVC : UITableViewController
- (instancetype)initWithArea:(WAGRGatingArea)area;
@end

NS_ASSUME_NONNULL_END
