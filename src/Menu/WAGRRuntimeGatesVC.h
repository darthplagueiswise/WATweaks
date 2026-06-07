// WAGRRuntimeGatesVC.h — root list of gate categories (providers).
// ─────────────────────────────────────────────────────────────────────────────
// This is the screen the user sees when tapping "Abrir Runtime Gates" from
// the root menu. It enumerates WAGRGateRegistry.allProviders and pushes a
// WAGRGateCategoryVC on tap. The cells show a live override count for each
// category so the user can spot at a glance where they've already changed
// things.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#import <UIKit/UIKit.h>

@interface WAGRRuntimeGatesVC : UITableViewController
@end
