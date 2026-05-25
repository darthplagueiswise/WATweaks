// WAGRGateCategoryVC.h — single category screen.
// ─────────────────────────────────────────────────────────────────────────────
// Layout
// ──────
// Section 0 — Featured flags (UISwitch per row, long-press to clear).
// Section 1 — Actions ("Runtime Avançado", "Reset overrides desta categoria").
//
// A featured flag write goes through WAGRGateSet/Clear (schema v2). On the
// first ON-write for a given selector, we also call
// WAGRGateInstallHookForSelector across the provider's concrete classes
// until one succeeds, so the override actually takes effect even if the
// constructor-time bootstrap didn't pick that selector up.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#import <UIKit/UIKit.h>
#import "../Runtime/WAGRGateRegistry.h"

@interface WAGRGateCategoryVC : UITableViewController
- (instancetype)initWithProvider:(WAGRGateProvider *)provider NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
@end
