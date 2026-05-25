// WAGRGateRuntimeBrowserVC.h — exhaustive selector browser for one category.
// ─────────────────────────────────────────────────────────────────────────────
// When the user taps "Runtime Avançado" on a category, this controller scans
// the provider's concrete classes plus any class whose name matches the
// provider's classNameFragments. Discovered BOOL no-arg methods (and
// declared properties of BOOL type) are surfaced as rows; the user can
// toggle each independently of the featured list.
//
// Performance notes
// ─────────────────
// The scan walks objc_copyClassList exactly once for fragment matches, then
// class_copyMethodList per matched class. For the registry's tight fragment
// lists this is fast (low single-digit milliseconds even on cold launches),
// but we still do it on viewDidLoad and cache the result. Switching back
// from the category screen does not re-scan.
//
// On switch ON, we call WAGRGateInstallHookForSelector with the exact
// (className, selectorName, isClassMethod) of the row, guaranteeing the
// override takes effect even for selectors that don't go through
// boolForKey:.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#import <UIKit/UIKit.h>
#import "../Runtime/WAGRGateRegistry.h"

@interface WAGRGateRuntimeBrowserVC : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithProvider:(WAGRGateProvider *)provider NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
@end
