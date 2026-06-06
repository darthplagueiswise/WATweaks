#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define WALog(fmt, ...) NSLog(@"[WATweaks] " fmt, ##__VA_ARGS__)

// Single persistence namespace. UI preferences use watweak_ui_* and runtime
// overrides use watweak_gate_* through WAGRGateStore. Old wa_/wagr keys are
// read only by migration/alias code and are not written by the new menus.
#define WA_PREF_KEYCHAIN_REWRITE @"watweak_ui_keychain_rewrite_enabled"
#define WA_PREF_KEYCHAIN_OBSERVER @"watweak_ui_keychain_observer_enabled"
#define WA_PREF_EMPLOYEE_MASTER @"watweak_ui_employee_master"
#define WA_PREF_AB_OBSERVER @"watweak_ui_abprops_observer_enabled"
#define WA_PREF_LIQUID_GLASS @"watweak_ui_liquid_glass_enabled"
#define WA_PREF_LIQUID_GLASS_USERDEFAULTS @"watweak_ui_liquid_glass_userdefaults_overrides"
#define WA_PREF_LIQUID_GLASS_METHOD_HOOKS @"watweak_ui_liquid_glass_method_hooks"
