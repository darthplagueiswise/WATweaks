// WAGramPrefix.h — single unified prefix for WATweaks.
// ─────────────────────────────────────────────────────────────────────────────
// Storage model (single source of truth, schema v2)
// ────────────────────────────────────────────────
// Override storage uses NSUserDefaults with one key per gate selector.
//
//   key   = exact selector or flag name (e.g. "isInternalUser",
//           "aura_enabled", "isM1Enabled", "ios_liquid_glass_m_1_5")
//   value = NSNumber BOOL (YES → force gate ON, NO → force gate OFF)
//   absent = no override; gate falls back to WhatsApp's original answer
//
// The legacy schemas (wagr.waab.<flag>=@"on"|@"off",
// wagr.override|objc|<cls>|<inst|class>|<sel>, wagr.observed|... and
// wagr.override.<surface>.<cls>.<mode>.<sel>) are obsolete. The storage
// layer (WAGRGateStore.h) wipes them on first launch of this build and
// records wagr.storage.wiped.v2=@YES so the wipe runs exactly once.
//
// Reserved namespace
// ──────────────────
// Everything WATweaks owns that is NOT a gate override lives under wagr.*
// (or under named master prefs defined below). Do not introduce new
// override-style keys with a wagr. prefix.
//
// Why one key per selector
// ────────────────────────
// • The same flag name can be queried by WAABProperties, WAContext,
//   FOAWAABPropertiesImpl, etc. With one key, all readers stay in sync.
// • The runtime browser can probe an arbitrary class for a selector and
//   immediately know whether an override exists, with no key parsing.
// • Backup/restore stays simple — every override is a top-level flat pair.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#endif
#import "WAPrefix.h"
#import "Runtime/WAGRGateStore.h"

// ── Master pref keys (NOT gate overrides; user-level switches) ───────────────
// These are stable, named NSUserDefaults keys that control WATweaks subsystems
// independently of any selector. They live alongside gate overrides but never
// collide because they're either qualified with wagr_/wagr. or with a custom
// prefix from WAPrefix.h.
#define kWAGRKeychain          WA_PREF_KEYCHAIN_REWRITE
#define kWAGRKeychainObserver  WA_PREF_KEYCHAIN_OBSERVER
#define kWAGREmployeeMaster    WA_PREF_EMPLOYEE_MASTER
#define kWAGRABPropsObserver   WA_PREF_AB_OBSERVER
#define kWAGRLiquidGlassMaster WA_PREF_LIQUID_GLASS
#define kWAGRDebugMode         @"watweak_ui_debug_mode_enabled"
#define kWAGRInternalMaster    @"watweak_bundle_internal_master"
#define kWAGRDebugMenuNative   @"watweak_gate_isDebugMenuAllowed"
#define kWAGRAuraSimulation    @"watweak_bundle_aura_simulation"

// ── Dogfood gate individual keys ──────────────────────────────────────────────
#define kWAGRDogfoodGateMetaEmployee      @"watweak_gate_isMetaEmployeeOrInternalTester"
#define kWAGRDogfoodGateMetaEmployeeSnake @"watweak_gate_is_meta_employee_or_internal_tester"
#define kWAGRDogfoodGateInternalUser      @"watweak_gate_isInternalUser"
#define kWAGRDogfoodGateGraphQLEmpC1      @"watweak_gate_graphQLEmployeeC1Disabled"

// ── LiquidGlass sub-prefs (legacy named keys consumed by WAGRLiquidGlassHooks)
#define kWAGRLiquidGlassUserDefaults @"wa_liquid_glass_userdefaults_overrides"
#define kWAGRLiquidGlassMethodHooks  @"wa_liquid_glass_method_hooks"

// ── Quick bool read for master prefs ─────────────────────────────────────────
#define WAGRPref(key) WAGRPreferenceEnabled((key))
static inline BOOL WAGRPreferenceEnabled(NSString *key) {
    if (!key.length) return NO;
    if ([key hasPrefix:@"watweak_gate_"] || [key hasPrefix:@"wagr.dogfood.gate."] || [key hasPrefix:@"wa_lg_ios_liquid_glass_"]) {
        return WAGRGateIsSet(key) ? WAGRGateGet(key) : NO;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}
