#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define WALog(fmt, ...) NSLog(@"[WATweaks] " fmt, ##__VA_ARGS__)

#define WA_PREF_KEYCHAIN_REWRITE @"watweak_keychain_rewrite_enabled"
#define WA_PREF_KEYCHAIN_OBSERVER @"watweak_keychain_observer_enabled"
#define WA_PREF_EMPLOYEE_MASTER @"watweak_bundle_employee_master"
#define WA_PREF_AB_OBSERVER @"watweak_abprops_observer_enabled"
#define WA_PREF_LIQUID_GLASS @"watweak_bundle_liquid_glass"
#define WA_PREF_LIQUID_GLASS_USERDEFAULTS @"watweak_liquid_glass_userdefaults_overrides"
#define WA_PREF_LIQUID_GLASS_METHOD_HOOKS @"watweak_liquid_glass_method_hooks"
