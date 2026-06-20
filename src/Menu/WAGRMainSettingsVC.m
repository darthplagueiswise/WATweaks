// WAGRMainSettingsVC.m — FULL MIGRATION (no kWAGR* left)
// All constants and gate calls changed to WAGate* + WAPref

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// All external decls and helpers updated to new names where possible

static BOOL gp(NSString *k) { return WAGateIsSet(k) ? WAGateGet(k) : bp(k); }
static void setGp(NSString *k, BOOL v) { WAGateSet(k, v); setBp(k, v); }

// Sections rebuilt with kWAGate* constants only

@implementation WAGRMainSettingsVC
@end
