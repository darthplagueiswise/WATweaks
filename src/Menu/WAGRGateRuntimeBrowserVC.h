// WAGRGateRuntimeBrowserVC.h — exhaustive selector browser for one category.
// ─────────────────────────────────────────────────────────────────────────────
// When the user taps "Runtime Avançado" on a category, this controller scans
// the provider's concrete classes plus any class whose name matches the
// provider's classNameFragments. Discovered BOOL no-arg methods are surfaced
// as rows; the user can toggle each independently of the featured list.
//
// Performance notes
// ─────────────────
// The scan walks objc_copyClassList exactly once for fragment matches, then
// class_copyMethodList per matched class. For the registry's tight fragment
// lists this is fast (low single-digit milliseconds even on cold launches),
// but we still do it on viewDidLoad and cache the result.
//
// On switch ON, we call WAGRGateInstallHookForSelector with the exact
// (className, selectorName, isClassMethod) of the row, guaranteeing the
// override takes effect even for selectors that don't go through
// boolForKey:.
//
// See WAGRGateCategoryVC.h for the rationale on not marking
// initWithProvider: as NS_DESIGNATED_INITIALIZER.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#import <UIKit/UIKit.h>
#import "../Runtime/WAGRGateRegistry.h"

@interface WAGRGateRuntimeBrowserVC : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithProvider:(WAGRGateProvider *)provider;
@end
