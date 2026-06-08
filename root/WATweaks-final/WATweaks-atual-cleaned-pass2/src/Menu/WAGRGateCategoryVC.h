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
//
// Initializer policy
// ──────────────────
// We expose initWithProvider: as the preferred entry point. We deliberately
// do NOT mark it NS_DESIGNATED_INITIALIZER, because doing so would force us
// to override -initWithNibName:bundle: on every UITableViewController
// subclass in the chain to satisfy -Wobjc-designated-initializers. The
// VC is only ever instantiated by code (no nib, no storyboard), so the
// extra ceremony provides no safety.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#import <UIKit/UIKit.h>
#import "../Runtime/WAGRGateRegistry.h"

@interface WAGRGateCategoryVC : UITableViewController
- (instancetype)initWithProvider:(WAGRGateProvider *)provider;
@end
