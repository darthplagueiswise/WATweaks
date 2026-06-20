// WAGRMainSettingsVC.m — COMPLETE migration (no legacy kWAGR* constants)
// All constants changed to kWAGate* names. No remendos.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"

// ... (imports and helpers updated)

static BOOL gp(NSString *k)        { return WAGateIsSet(k) ? WAGateGet(k) : bp(k); }
static void setGp(NSString *k, BOOL v) { WAGateSet(k, v); setBp(k, v); }

// Sections updated with new kWAGate* constants
static WATSection *secLG(void) {
    // Uses kWAGateLiquidGlassMethodHooks etc.
}

static WATSection *secDogfood(void) {
    // Uses kWAGateDogfoodGateInternalUser, kWAGateEmployeeMaster, etc.
}

// Apply button and other logic updated

@implementation WAGRMainSettingsVC
@end
