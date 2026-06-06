// WAGRSettingsRowsNativeHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Native Settings-row feature hooks.
//
// This file no longer adds a WATweaks row/button to WhatsApp Settings or
// Developer menus. It only keeps the Settings Rows feature hooks that expose
// WhatsApp's own subscriptions/payments rows when their gates are enabled.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Menu/WAGRSurfaceListVC.h"

extern "C" NSUInteger WAGRReinstallPersistedHooks(void);
extern "C" void WAGRWAABEnsureHooksInstalled(void);
extern "C" void WAGRAuraEnsureHooksInstalled(void);
extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern "C" void WAGRAccountEligibilityEnsureHooksInstalled(void);

static BOOL gWAGRSettingsRowsAttempted = NO;
static BOOL gWAGRSettingsRowsHooksInstalled = NO;
static BOOL gWAGRSettingsRowsButtonInserted = NO;
static NSUInteger gWAGRSettingsRowsInstalledHookCount = 0;
static NSUInteger gWAGRSettingsRowsInjectAttempts = 0;
static NSUInteger gWAGRSettingsRowsSubscriptionForces = 0;
static NSUInteger gWAGRSettingsRowsPaymentsForces = 0;
static NSString *gWAGRSettingsRowsLastError = nil;

static const void *kWAGRNativeSettingsRefreshMarker = &kWAGRNativeSettingsRefreshMarker;

static void (*origCheckSubscriptionsEligibility)(id, SEL) = NULL;
static BOOL (*origIsSubscriptionsRowPresent)(id, SEL) = NULL;
static void (*origRemoveSubscriptionsRow)(id, SEL) = NULL;
static void (*origInsertSubscriptionsRow)(id, SEL) = NULL;
static void (*origAddSubscriptionsRowToSection)(id, SEL, id) = NULL;
static id (*origCreatePaymentRowIfNeeded)(id, SEL) = NULL;
static void (*origAddPaymentsRowToSection)(id, SEL, id) = NULL;
static BOOL (*origShowBRConsumerPaymentsHome)(id, SEL) = NULL;
static id (*origGetSettingsViewModel)(id, SEL) = NULL;
static id (*origCreateSettingsEntryPointViewModel)(id, SEL) = NULL;
static void (*origSettingsViewDidLoad)(id, SEL) = NULL;
static void (*origSettingsViewDidAppear)(id, SEL, BOOL) = NULL;

static void WAGRSetLastSettingsRowsError(NSString *error) {
    gWAGRSettingsRowsLastError = [error copy];
}

static BOOL WAGRIsWASettingsVC(id obj) {
    if (!obj) return NO;
    NSString *name = NSStringFromClass([obj class]);
    return [name isEqualToString:@"WASettingsViewController"] || [name containsString:@"WASettingsViewController"];
}


/* WATweaks native menu entry intentionally removed. Use long-press/global launcher only. */

static BOOL WAGRWAABAnyOn(NSArray<NSString *> *flags) {
    for (NSString *flag in flags) if (WAGRIsOn(flag)) return YES;
    return NO;
}

static BOOL WAGRSettingsRowsShouldForceSubscriptions(void) {
    if (WAGRPref(@"wagr.settingsrows.force_subscriptions")) return YES;
    return WAGRWAABAnyOn(@[
        @"aura_enabled",
        @"aura_settings_row_enabled",
        @"aura_subscription_simulation_enabled",
        @"wa_subscriptions_entry_point_settings_enabled",
        @"wa_plus_settings_row_enabled",
        @"wa_plus_custom_ringtones",
        @"meta_subs_benefit_wa_ringtones_upsell",
        @"isEligibleForSubscriptions",
        @"isSubscribedToAiBenefit",
        @"isAISubscriptionEnabled"
    ]);
}

static BOOL WAGRSettingsRowsShouldForcePayments(void) {
    if (WAGRPref(@"wagr.settingsrows.force_payments")) return YES;
    return WAGRWAABAnyOn(@[
        @"br_consumer_payments_home_enabled",
        @"br_consumer_paymentshome_enabled",
        @"payments_home_revamp_m1_enabled",
        @"payments_home_revamp_landing_screen_enabled",
        @"payments_home_ui_updates_enabled",
        @"payment_settings_add_bank_account_row",
        @"payment_settings_add_upi_number_row",
        @"payment_settings_add_bank_banner",
        @"payment_settings_invite_others_row",
        @"payment_settings_remove_payment_info_row",
        @"br_payments_pix_native_enabled",
        @"br_payments_pix_groups_enabled",
        @"br_p2p_add_pix_key_from_payment_settings",
        @"br_payment_smb_connect_to_bank_enabled",
        @"enable_payment_passkey",
        @"br_payments_passkey_enable"
    ]);
}

static void WAGRSettingsRowsEnsureRuntimeOwners(void) {
    // Settings-only path. Tweak.x calls this only after WASettingsViewController
    // is already visible or when the debug menu explicitly requests diagnostics.
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRReinstallPersistedHooks();
}

static void WAGRInstallSettingsBarButton(id settingsVC) {
    (void)settingsVC;
    // No injected WATweaks row/bar button in WhatsApp native menus.
    gWAGRSettingsRowsButtonInserted = NO;
}

extern "C" void WAGRSettingsRowsNativeInjectIfPossible(id maybeSettingsVC) {
    (void)maybeSettingsVC;
    // Compatibility no-op: do not mutate WASettingsViewController for WATweaks entry.
}

static BOOL WAGROrigSubscriptionsRowPresent(id self) {
    if (origIsSubscriptionsRowPresent) return origIsSubscriptionsRowPresent(self, NSSelectorFromString(@"isSubscriptionsRowPresentInTable"));
    return NO;
}

static void WAGRForceSubscriptionsRowIfNeeded(id settingsVC) {
    if (!WAGRIsWASettingsVC(settingsVC) || !WAGRSettingsRowsShouldForceSubscriptions()) return;
    if ([objc_getAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker) boolValue]) return;
    objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (WAGROrigSubscriptionsRowPresent(settingsVC)) return;
        gWAGRSettingsRowsSubscriptionForces++;
        if ([settingsVC respondsToSelector:NSSelectorFromString(@"insertSubscriptionsRow")]) {
            ((void (*)(id, SEL))objc_msgSend)(settingsVC, NSSelectorFromString(@"insertSubscriptionsRow"));
        }
    });
}

static void WAGRForcePaymentsIfNeeded(id settingsVC) {
    if (!WAGRIsWASettingsVC(settingsVC) || !WAGRSettingsRowsShouldForcePayments()) return;
    gWAGRSettingsRowsPaymentsForces++;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"wagr.settingsrows.force_payments"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    WAGRAccountEligibilityEnsureHooksInstalled();
}

static void WAGRRefreshSettingsRowsSoon(id settingsVC) {
    if (!WAGRIsWASettingsVC(settingsVC)) return;
    WAGRSettingsRowsEnsureRuntimeOwners();
    WAGRInstallSettingsBarButton(settingsVC);
    WAGRForceSubscriptionsRowIfNeeded(settingsVC);
    WAGRForcePaymentsIfNeeded(settingsVC);
}

static void hookCheckSubscriptionsEligibility(id self, SEL _cmd) {
    if (origCheckSubscriptionsEligibility) origCheckSubscriptionsEligibility(self, _cmd);
    WAGRForceSubscriptionsRowIfNeeded(self);
}

static BOOL hookIsSubscriptionsRowPresent(id self, SEL _cmd) {
    BOOL original = origIsSubscriptionsRowPresent ? origIsSubscriptionsRowPresent(self, _cmd) : NO;

    // This method answers "is the Subscriptions row present?". When the
    // Aura/WA Plus chain is forced, the externally visible answer should be
    // YES. Insertion is handled separately by WAGRForceSubscriptionsRowIfNeeded
    // using the original IMP, so returning YES here no longer blocks our own
    // insertion path.
    if (WAGRSettingsRowsShouldForceSubscriptions()) return YES;
    return original;
}

static void hookRemoveSubscriptionsRow(id self, SEL _cmd) {
    if (WAGRSettingsRowsShouldForceSubscriptions()) return;
    if (origRemoveSubscriptionsRow) origRemoveSubscriptionsRow(self, _cmd);
}

static void hookInsertSubscriptionsRow(id self, SEL _cmd) {
    if (origInsertSubscriptionsRow) origInsertSubscriptionsRow(self, _cmd);
}

static void hookAddSubscriptionsRowToSection(id self, SEL _cmd, id section) {
    if (origAddSubscriptionsRowToSection) origAddSubscriptionsRowToSection(self, _cmd, section);
}

static id hookCreatePaymentRowIfNeeded(id self, SEL _cmd) {
    if (WAGRSettingsRowsShouldForcePayments()) {
        gWAGRSettingsRowsPaymentsForces++;
    }
    return origCreatePaymentRowIfNeeded ? origCreatePaymentRowIfNeeded(self, _cmd) : nil;
}

static void hookAddPaymentsRowToSection(id self, SEL _cmd, id section) {
    if (origAddPaymentsRowToSection) origAddPaymentsRowToSection(self, _cmd, section);
}

static BOOL hookShowBRConsumerPaymentsHome(id self, SEL _cmd) {
    if (WAGRSettingsRowsShouldForcePayments()) return YES;
    return origShowBRConsumerPaymentsHome ? origShowBRConsumerPaymentsHome(self, _cmd) : NO;
}

static id hookGetSettingsViewModel(id self, SEL _cmd) {
    id result = origGetSettingsViewModel ? origGetSettingsViewModel(self, _cmd) : nil;
    WAGRRefreshSettingsRowsSoon(self);
    return result;
}

static id hookCreateSettingsEntryPointViewModel(id self, SEL _cmd) {
    id result = origCreateSettingsEntryPointViewModel ? origCreateSettingsEntryPointViewModel(self, _cmd) : nil;
    WAGRRefreshSettingsRowsSoon(self);
    return result;
}

static void hookSettingsViewDidLoad(id self, SEL _cmd) {
    if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);
    WAGRRefreshSettingsRowsSoon(self);
}

static void hookSettingsViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (origSettingsViewDidAppear) origSettingsViewDidAppear(self, _cmd, animated);
    WAGRRefreshSettingsRowsSoon(self);
}

static BOOL WAGRHookInstance(Class cls, NSString *selName, IMP replacement, IMP *origOut) {
    if (!cls || !selName.length || !replacement || !origOut || *origOut) return NO;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    MSHookMessageEx(cls, sel, replacement, origOut);
    return (*origOut != NULL);
}

extern "C" void WAGRSettingsRowsNativeEnsureHooksInstalled(void) {
    gWAGRSettingsRowsAttempted = YES;
    if (gWAGRSettingsRowsHooksInstalled) return;

    Class cls = NSClassFromString(@"WASettingsViewController");
    if (!cls) {
        WAGRSetLastSettingsRowsError(@"WASettingsViewController not loaded yet");
        return;
    }

    NSUInteger installed = 0;
    if (WAGRHookInstance(cls, @"checkSubscriptionsEligibilityAndInsertRowIfNeeded", (IMP)hookCheckSubscriptionsEligibility, (IMP *)&origCheckSubscriptionsEligibility)) installed++;
    if (WAGRHookInstance(cls, @"isSubscriptionsRowPresentInTable", (IMP)hookIsSubscriptionsRowPresent, (IMP *)&origIsSubscriptionsRowPresent)) installed++;
    if (WAGRHookInstance(cls, @"removeSubscriptionsRow", (IMP)hookRemoveSubscriptionsRow, (IMP *)&origRemoveSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"insertSubscriptionsRow", (IMP)hookInsertSubscriptionsRow, (IMP *)&origInsertSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"addSubscriptionsRowToSection:", (IMP)hookAddSubscriptionsRowToSection, (IMP *)&origAddSubscriptionsRowToSection)) installed++;
    if (WAGRHookInstance(cls, @"createPaymentRowIfNeeded", (IMP)hookCreatePaymentRowIfNeeded, (IMP *)&origCreatePaymentRowIfNeeded)) installed++;
    if (WAGRHookInstance(cls, @"addPaymentsRowToSection:", (IMP)hookAddPaymentsRowToSection, (IMP *)&origAddPaymentsRowToSection)) installed++;
    if (WAGRHookInstance(cls, @"showBRConsumerPaymentsHome", (IMP)hookShowBRConsumerPaymentsHome, (IMP *)&origShowBRConsumerPaymentsHome)) installed++;
    if (WAGRHookInstance(cls, @"getSettingsViewModel", (IMP)hookGetSettingsViewModel, (IMP *)&origGetSettingsViewModel)) installed++;
    if (WAGRHookInstance(cls, @"createSettingsEntryPointViewModel", (IMP)hookCreateSettingsEntryPointViewModel, (IMP *)&origCreateSettingsEntryPointViewModel)) installed++;
    if (WAGRHookInstance(cls, @"viewDidLoad", (IMP)hookSettingsViewDidLoad, (IMP *)&origSettingsViewDidLoad)) installed++;
    if (WAGRHookInstance(cls, @"viewDidAppear:", (IMP)hookSettingsViewDidAppear, (IMP *)&origSettingsViewDidAppear)) installed++;

    gWAGRSettingsRowsInstalledHookCount = installed;
    gWAGRSettingsRowsHooksInstalled = installed > 0;
    if (!gWAGRSettingsRowsHooksInstalled) WAGRSetLastSettingsRowsError(@"WASettingsViewController found, but none of the expected selectors were hookable");
    else WAGRSetLastSettingsRowsError(nil);
}

extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) {
    return gWAGRSettingsRowsButtonInserted;
}

extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"attempted=%@\nhooksInstalled=%@\ninstalledHookCount=%lu\nsettingsClass=%@\nsettingsButtonInserted=%@ (native WATweaks entry disabled)\ninjectAttempts=%lu\nsubscriptionForceCount=%lu\npaymentsForceCount=%lu\nforceSubscriptions=%@\nforcePayments=%@\nlastError=%@",
            gWAGRSettingsRowsAttempted ? @"YES" : @"NO",
            gWAGRSettingsRowsHooksInstalled ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInstalledHookCount,
            NSClassFromString(@"WASettingsViewController") ? @"found" : @"missing",
            gWAGRSettingsRowsButtonInserted ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInjectAttempts,
            (unsigned long)gWAGRSettingsRowsSubscriptionForces,
            (unsigned long)gWAGRSettingsRowsPaymentsForces,
            WAGRSettingsRowsShouldForceSubscriptions() ? @"YES" : @"NO",
            WAGRSettingsRowsShouldForcePayments() ? @"YES" : @"NO",
            gWAGRSettingsRowsLastError ?: @"none"];
}
