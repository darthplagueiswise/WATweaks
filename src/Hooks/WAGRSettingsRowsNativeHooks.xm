// WAGRSettingsRowsNativeHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Watusi-style Settings entry for WATweaks.
//
// The Watusi IPA does not rely on fragile UITableViewCellContentView mutation.
// It ships its own settings stack (WSSettings / WSSettingsController / sections)
// and presents that stack from WhatsApp settings. The safe equivalent here is:
//   • do not mutate WhatsApp's WATableSection rows for our own menu;
//   • add a retained UIBarButtonItem to WASettingsViewController when that VC is
//     already visible;
//   • keep the existing long-press path as the only fallback;
//   • keep native hidden-row hooks limited to boolean/provider methods.
//
// No constructor. No UIKit footer fallback. No broad ivar scan. No WATableRow custom
// injection for WATweaks/Developer/Payments.
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

static BOOL gWAGRSettingsRowsAttempted = NO;
static BOOL gWAGRSettingsRowsHooksInstalled = NO;
static BOOL gWAGRSettingsRowsButtonInserted = NO;
static NSUInteger gWAGRSettingsRowsInstalledHookCount = 0;
static NSUInteger gWAGRSettingsRowsInjectAttempts = 0;
static NSUInteger gWAGRSettingsRowsSubscriptionForces = 0;
static NSUInteger gWAGRSettingsRowsPaymentsForces = 0;
static NSString *gWAGRSettingsRowsLastError = nil;

static const void *kWAGRSettingsButtonTargetKey = &kWAGRSettingsButtonTargetKey;
static const void *kWAGRSettingsButtonInstalledKey = &kWAGRSettingsButtonInstalledKey;
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

static void WAGRSetLastSettingsRowsError(NSString *error) {
    gWAGRSettingsRowsLastError = [error copy];
}

static BOOL WAGRIsWASettingsVC(id obj) {
    if (!obj) return NO;
    NSString *name = NSStringFromClass([obj class]);
    return [name isEqualToString:@"WASettingsViewController"] || [name containsString:@"WASettingsViewController"];
}

static UIViewController *WAGRTopViewController(void) {
    UIViewController *root = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (!win.isHidden && win.rootViewController) { root = win.rootViewController; break; }
    }
    if (!root) root = UIApplication.sharedApplication.keyWindow.rootViewController;
    UIViewController *p = root;
    while (p.presentedViewController) p = p.presentedViewController;
    if ([p isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)p).topViewController;
        if (top) p = top;
    }
    return p;
}

static UIViewController *WAGRPresenterForSettings(id settingsVC) {
    if ([settingsVC isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)settingsVC;
        UIViewController *p = vc;
        while (p.presentedViewController) p = p.presentedViewController;
        return p;
    }
    return WAGRTopViewController();
}

static void WAGRPresentWATweaksMenuFromSettings(id settingsVC) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = WAGRPresenterForSettings(settingsVC);
        if (!host) return;
        WAGRSurfaceListVC *menu = [[WAGRSurfaceListVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:menu];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            sheet.prefersGrabberVisible = YES;
            sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        }
        [host presentViewController:nav animated:YES completion:nil];
    });
}

@interface WAGRSettingsButtonTarget : NSObject
@property(nonatomic, assign) id settingsVC;
+ (instancetype)targetForSettingsVC:(id)settingsVC;
- (void)openWATweaks:(id)sender;
@end

@implementation WAGRSettingsButtonTarget
+ (instancetype)targetForSettingsVC:(id)settingsVC {
    WAGRSettingsButtonTarget *target = objc_getAssociatedObject(settingsVC, kWAGRSettingsButtonTargetKey);
    if (!target) {
        target = [WAGRSettingsButtonTarget new];
        target.settingsVC = settingsVC;
        objc_setAssociatedObject(settingsVC, kWAGRSettingsButtonTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return target;
}
- (void)openWATweaks:(id)sender {
    (void)sender;
    WAGRPresentWATweaksMenuFromSettings(self.settingsVC);
}
@end

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
    if (!WAGRIsWASettingsVC(settingsVC) || ![settingsVC isKindOfClass:UIViewController.class]) return;
    gWAGRSettingsRowsInjectAttempts++;

    if ([objc_getAssociatedObject(settingsVC, kWAGRSettingsButtonInstalledKey) boolValue]) return;

    UIViewController *vc = (UIViewController *)settingsVC;
    UINavigationItem *item = vc.navigationItem;
    if (!item) return;

    NSMutableArray<UIBarButtonItem *> *items = item.rightBarButtonItems ? [item.rightBarButtonItems mutableCopy] : [NSMutableArray array];
    for (UIBarButtonItem *existing in items) {
        if ([existing.accessibilityIdentifier isEqualToString:@"WATweaksSettingsButton"]) {
            objc_setAssociatedObject(settingsVC, kWAGRSettingsButtonInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            gWAGRSettingsRowsButtonInserted = YES;
            return;
        }
    }

    UIImage *image = nil;
    if (@available(iOS 13.0, *)) {
        image = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
        if (!image) image = [UIImage systemImageNamed:@"curlybraces"];
        if (!image) image = [UIImage systemImageNamed:@"gearshape"];
    }

    WAGRSettingsButtonTarget *target = [WAGRSettingsButtonTarget targetForSettingsVC:settingsVC];
    UIBarButtonItem *button = nil;
    if (image) button = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:target action:@selector(openWATweaks:)];
    else button = [[UIBarButtonItem alloc] initWithTitle:@"WAT" style:UIBarButtonItemStylePlain target:target action:@selector(openWATweaks:)];

    button.accessibilityIdentifier = @"WATweaksSettingsButton";
    button.accessibilityLabel = @"WATweaks";

    // Insert before WhatsApp's own QR/search items instead of replacing them.
    [items insertObject:button atIndex:0];
    item.rightBarButtonItems = items;

    objc_setAssociatedObject(settingsVC, kWAGRSettingsButtonInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gWAGRSettingsRowsButtonInserted = YES;
    WAGRSetLastSettingsRowsError(nil);
    NSLog(@"[WATweaks][NativeSettingsRows] installed WATweaks settings bar button");
}

extern "C" void WAGRSettingsRowsNativeInjectIfPossible(id maybeSettingsVC) {
    if (!WAGRIsWASettingsVC(maybeSettingsVC)) return;
    WAGRInstallSettingsBarButton(maybeSettingsVC);
}

static BOOL WAGROrigSubscriptionsRowPresent(id self) {
    if (origIsSubscriptionsRowPresent) return origIsSubscriptionsRowPresent(self, NSSelectorFromString(@"isSubscriptionsRowPresentInTable"));
    return NO;
}

// Associated-object marker: have we successfully forced an insert on THIS
// settings VC instance yet? The marker is used by hookIsSubscriptionsRowPresent
// so that we only claim "present" to WhatsApp AFTER we have actually inserted
// the row — claiming "present" beforehand would sabotage WhatsApp's own
// checkSubscriptionsEligibilityAndInsertRowIfNeeded → insertSubscriptionsRow
// pipeline (because that pipeline early-returns if the row is "already present").
static const void *kWAGRSubsRowInsertedMarker = &kWAGRSubsRowInsertedMarker;

static BOOL WAGRSubsRowAlreadyForced(id settingsVC) {
    return [objc_getAssociatedObject(settingsVC, kWAGRSubsRowInsertedMarker) boolValue];
}

static void WAGRForceSubscriptionsRowIfNeeded(id settingsVC) {
    if (!WAGRIsWASettingsVC(settingsVC) || !WAGRSettingsRowsShouldForceSubscriptions()) return;
    if (WAGRSubsRowAlreadyForced(settingsVC)) return;
    if ([objc_getAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker) boolValue]) return;
    objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // PREVIOUSLY: we early-returned here when WAGROrigSubscriptionsRowPresent
        // was YES. That was the bug: WhatsApp's `_subscriptionsRow` ivar can
        // already be non-nil at startup (row object exists in memory but is
        // not yet attached to the visible section), so the orig check returned
        // YES and our force never ran — visible-on-screen count stayed at 0.
        // We now call insertSubscriptionsRow unconditionally; the WhatsApp
        // implementation itself is responsible for handling the "already
        // attached" case idempotently. We then mark the VC as forced so the
        // hookIsSubscriptionsRowPresent guard knows when to return YES.
        gWAGRSettingsRowsSubscriptionForces++;
        if ([settingsVC respondsToSelector:NSSelectorFromString(@"insertSubscriptionsRow")]) {
            ((void (*)(id, SEL))objc_msgSend)(settingsVC, NSSelectorFromString(@"insertSubscriptionsRow"));
            objc_setAssociatedObject(settingsVC, kWAGRSubsRowInsertedMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

static void WAGRForcePaymentsIfNeeded(id settingsVC) {
    if (!WAGRIsWASettingsVC(settingsVC) || !WAGRSettingsRowsShouldForcePayments()) return;
    gWAGRSettingsRowsPaymentsForces++;
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
    // PREVIOUSLY: this returned YES whenever forceSubscriptions was on,
    // unconditionally. That was wrong: WhatsApp's own
    // checkSubscriptionsEligibilityAndInsertRowIfNeeded uses this method as
    // the "already-inserted, skip" guard. Returning YES *before* the row was
    // actually inserted meant WA skipped its own insert path entirely.
    //
    // The correct behavior:
    //   * If we have already forced an insert on this VC, claim YES so any
    //     subsequent re-evaluation by WA (e.g. removeSubscriptionsRow check)
    //     keeps the row alive.
    //   * Otherwise return whatever WhatsApp's own method returned. WA's
    //     insert logic then runs normally, and our force runs on top as
    //     a belt-and-suspenders guarantee.
    if (WAGRSettingsRowsShouldForceSubscriptions() && WAGRSubsRowAlreadyForced(self)) {
        return YES;
    }
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
            @"attempted=%@\nhooksInstalled=%@\ninstalledHookCount=%lu\nsettingsClass=%@\nsettingsButtonInserted=%@\ninjectAttempts=%lu\nsubscriptionForceCount=%lu\npaymentsForceCount=%lu\nforceSubscriptions=%@\nforcePayments=%@\nlastError=%@",
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
