// WAGRSettingsRowsNativeHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Native WASettingsViewController integration.
//
// WhatsApp's Settings screen is not a plain UITableView data source we own.
// The real list is built by WASettingsViewController using WATableSection and
// WATableRow. This file hooks that native builder and inserts WATweaks as a
// real WATableRow immediately after WhatsApp creates the Storage & Data row.
//
// Fallback policy:
//   • no UIKit footer row here;
//   • if native insertion fails, the existing long-press path in Tweak.x is the only fallback.
//
// Keep this file focused: native Settings rows only.
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
static BOOL gWAGRSettingsRowsNativeRowInserted = NO;
static BOOL gWAGRSettingsRowsFactoryFailed = NO;
static NSUInteger gWAGRSettingsRowsInstalledHookCount = 0;
static NSUInteger gWAGRSettingsRowsInsertAttempts = 0;
static NSUInteger gWAGRSettingsRowsSubscriptionForces = 0;
static NSString *gWAGRSettingsRowsLastError = nil;

static const void *kWAGRNativeSettingsRowMarker = &kWAGRNativeSettingsRowMarker;
static const void *kWAGRNativeSettingsRefreshMarker = &kWAGRNativeSettingsRefreshMarker;
static const void *kWAGRNativeSettingsHandlerMarker = &kWAGRNativeSettingsHandlerMarker;

static void (*origAddStorageAndDataRow)(id, SEL, id, id) = NULL;
static void (*origCheckSubscriptionsEligibility)(id, SEL) = NULL;
static BOOL (*origIsSubscriptionsRowPresent)(id, SEL) = NULL;
static void (*origRemoveSubscriptionsRow)(id, SEL) = NULL;
static void (*origInsertSubscriptionsRow)(id, SEL) = NULL;
static void (*origAddSubscriptionsRowToSection)(id, SEL, id) = NULL;
static id (*origGetSettingsViewModel)(id, SEL) = NULL;
static id (*origCreateSettingsEntryPointViewModel)(id, SEL) = NULL;

static void WAGRSetLastSettingsRowsError(NSString *error) {
    gWAGRSettingsRowsLastError = [error copy];
}

static UIViewController *WAGRTopViewController(void) {
    UIViewController *root = nil;

    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (!win.isHidden && win.rootViewController) {
            root = win.rootViewController;
            break;
        }
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

static BOOL WAGRResponds(id obj, NSString *selectorName) {
    return obj && [obj respondsToSelector:NSSelectorFromString(selectorName)];
}

static void WAGRCallVoid1(id obj, NSString *selectorName, id arg) {
    if (!WAGRResponds(obj, selectorName)) return;
    SEL sel = NSSelectorFromString(selectorName);
    ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

static BOOL WAGRWAABAnyOn(NSArray<NSString *> *flags) {
    for (NSString *flag in flags) {
        if (WAGRIsOn(flag)) return YES;
    }
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
        @"isEligibleForSubscriptions",
        @"isSubscribedToAiBenefit",
        @"isAISubscriptionEnabled"
    ]);
}

static BOOL WAGRSettingsRowsShouldForceDeveloper(void) {
    if (WAGRPref(@"wagr.settingsrows.force_developer")) return YES;
    if (WAGRPref(kWAGRDebugMenuNative) ||
        WAGRPref(kWAGRInternalMaster) ||
        WAGRPref(kWAGREmployeeMaster) ||
        WAGRPref(kWAGRDebugMode)) return YES;

    return WAGRWAABAnyOn(@[
        @"sections_in_help_menu",
        @"mobile_config_debug_internal",
        @"dogfooder_diagnostics",
        @"ios_internal_hall_enabled",
        @"is_internal_tester"
    ]);
}

static void WAGRSettingsRowsEnsureRuntimeOwners(void) {
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRReinstallPersistedHooks();
}

static id WAGRCreateWATweaksNativeRow(id settingsVC) {
    if (!settingsVC) return nil;

    SEL factory = NSSelectorFromString(@"tableRowWithIdentifier:type:handler:");
    if (![settingsVC respondsToSelector:factory]) {
        gWAGRSettingsRowsFactoryFailed = YES;
        WAGRSetLastSettingsRowsError(@"WASettingsViewController lacks tableRowWithIdentifier:type:handler:");
        return nil;
    }

    __weak id weakSettings = settingsVC;
    id handler = [^(__unused id row, __unused id cell) {
        WAGRPresentWATweaksMenuFromSettings(weakSettings);
    } copy];

    objc_setAssociatedObject(settingsVC,
                             kWAGRNativeSettingsHandlerMarker,
                             handler,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id row = nil;
    NSArray<NSNumber *> *candidateTypes = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10];

    for (NSNumber *n in candidateTypes) {
        NSInteger type = n.integerValue;
        @try {
            row = ((id (*)(id, SEL, NSString *, NSInteger, id))objc_msgSend)(settingsVC,
                                                                              factory,
                                                                              @"SettingsView_WATweaksCell",
                                                                              type,
                                                                              handler);
        } @catch (__unused id ex) {
            row = nil;
        }

        if (row) break;
    }

    if (!row) {
        gWAGRSettingsRowsFactoryFailed = YES;
        WAGRSetLastSettingsRowsError(@"tableRowWithIdentifier:type:handler: returned nil for all candidate types");
        return nil;
    }

    NSArray<NSString *> *stringSetters = @[
        @"setTitle:",
        @"setName:",
        @"setText:",
        @"setDisplayName:",
        @"setAccessibilityLabel:",
        @"setAccessibilityIdentifier:",
        @"setIdentifier:"
    ];

    for (NSString *selName in stringSetters) {
        SEL sel = NSSelectorFromString(selName);
        if (![row respondsToSelector:sel]) continue;

        id value = ([selName isEqualToString:@"setAccessibilityIdentifier:"] ||
                    [selName isEqualToString:@"setIdentifier:"])
            ? @"SettingsView_WATweaksCell"
            : @"WATweaks";

        WAGRCallVoid1(row, selName, value);
    }

    if ([row respondsToSelector:NSSelectorFromString(@"setImage:")]) {
        UIImage *icon = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
        if (!icon) icon = [UIImage systemImageNamed:@"curlybraces"];
        if (icon) WAGRCallVoid1(row, @"setImage:", icon);
    }

    return row;
}

static BOOL WAGRAddRowToSection(id section, id row) {
    if (!section || !row) return NO;

    NSArray<NSString *> *selectors = @[
        @"addRow:",
        @"appendRow:",
        @"addTableRow:",
        @"addObject:"
    ];

    for (NSString *selName in selectors) {
        if (![section respondsToSelector:NSSelectorFromString(selName)]) continue;
        WAGRCallVoid1(section, selName, row);
        return YES;
    }

    WAGRSetLastSettingsRowsError([NSString stringWithFormat:@"section %@ has no known add-row selector",
                                  NSStringFromClass([section class])]);
    return NO;
}

static void WAGRInsertWATweaksRowIfNeeded(id settingsVC, id section) {
    if (!settingsVC || !section) return;
    gWAGRSettingsRowsInsertAttempts++;

    if ([objc_getAssociatedObject(section, kWAGRNativeSettingsRowMarker) boolValue]) return;

    id row = WAGRCreateWATweaksNativeRow(settingsVC);
    if (!row) return;

    if (!WAGRAddRowToSection(section, row)) return;

    objc_setAssociatedObject(section,
                             kWAGRNativeSettingsRowMarker,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    gWAGRSettingsRowsNativeRowInserted = YES;
    gWAGRSettingsRowsFactoryFailed = NO;
    WAGRSetLastSettingsRowsError(nil);
    NSLog(@"[WATweaks][NativeSettingsRows] inserted WATweaks WATableRow into %@",
          NSStringFromClass([section class]));
}

static BOOL WAGROrigSubscriptionsRowPresent(id self) {
    if (origIsSubscriptionsRowPresent) {
        return origIsSubscriptionsRowPresent(self, NSSelectorFromString(@"isSubscriptionsRowPresentInTable"));
    }
    return NO;
}

static void WAGRForceSubscriptionsRowIfNeeded(id settingsVC) {
    if (!settingsVC || !WAGRSettingsRowsShouldForceSubscriptions()) return;
    if ([objc_getAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker) boolValue]) return;

    objc_setAssociatedObject(settingsVC,
                             kWAGRNativeSettingsRefreshMarker,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(settingsVC,
                                 kWAGRNativeSettingsRefreshMarker,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (WAGROrigSubscriptionsRowPresent(settingsVC)) return;

        gWAGRSettingsRowsSubscriptionForces++;

        if ([settingsVC respondsToSelector:NSSelectorFromString(@"insertSubscriptionsRow")]) {
            ((void (*)(id, SEL))objc_msgSend)(settingsVC, NSSelectorFromString(@"insertSubscriptionsRow"));
            NSLog(@"[WATweaks][NativeSettingsRows] forced insertSubscriptionsRow");
            return;
        }

        Ivar sectionIvar = class_getInstanceVariable([settingsVC class], "_subscriptionsSection");
        id section = sectionIvar ? object_getIvar(settingsVC, sectionIvar) : nil;

        if (section && [settingsVC respondsToSelector:NSSelectorFromString(@"addSubscriptionsRowToSection:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(settingsVC,
                                                  NSSelectorFromString(@"addSubscriptionsRowToSection:"),
                                                  section);
            NSLog(@"[WATweaks][NativeSettingsRows] forced addSubscriptionsRowToSection:");
            return;
        }

        WAGRSetLastSettingsRowsError(@"could not force subscriptions row: no insert method/section available");
    });
}

static void WAGRRefreshSettingsRowsSoon(id settingsVC) {
    if (!settingsVC) return;
    WAGRSettingsRowsEnsureRuntimeOwners();
    WAGRForceSubscriptionsRowIfNeeded(settingsVC);
}

static void hookAddStorageAndDataRow(id self, SEL _cmd, id section, id settingTypeToRow) {
    if (origAddStorageAndDataRow) origAddStorageAndDataRow(self, _cmd, section, settingTypeToRow);
    WAGRInsertWATweaksRowIfNeeded(self, section);
    WAGRRefreshSettingsRowsSoon(self);
}

static void hookCheckSubscriptionsEligibility(id self, SEL _cmd) {
    if (origCheckSubscriptionsEligibility) origCheckSubscriptionsEligibility(self, _cmd);
    WAGRForceSubscriptionsRowIfNeeded(self);
}

static BOOL hookIsSubscriptionsRowPresent(id self, SEL _cmd) {
    BOOL original = origIsSubscriptionsRowPresent ? origIsSubscriptionsRowPresent(self, _cmd) : NO;
    if (WAGRSettingsRowsShouldForceSubscriptions()) return YES;
    return original;
}

static void hookRemoveSubscriptionsRow(id self, SEL _cmd) {
    if (WAGRSettingsRowsShouldForceSubscriptions()) {
        NSLog(@"[WATweaks][NativeSettingsRows] blocked removeSubscriptionsRow while subscriptions are forced");
        return;
    }
    if (origRemoveSubscriptionsRow) origRemoveSubscriptionsRow(self, _cmd);
}

static void hookInsertSubscriptionsRow(id self, SEL _cmd) {
    if (origInsertSubscriptionsRow) origInsertSubscriptionsRow(self, _cmd);
}

static void hookAddSubscriptionsRowToSection(id self, SEL _cmd, id section) {
    if (origAddSubscriptionsRowToSection) origAddSubscriptionsRowToSection(self, _cmd, section);
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
    if (!cls || !selName.length || !replacement || !origOut) return NO;

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

    if (WAGRHookInstance(cls, @"addStorageAndDataRowToWATableSection:settingTypeToRow:", (IMP)hookAddStorageAndDataRow, (IMP *)&origAddStorageAndDataRow)) installed++;
    if (WAGRHookInstance(cls, @"checkSubscriptionsEligibilityAndInsertRowIfNeeded", (IMP)hookCheckSubscriptionsEligibility, (IMP *)&origCheckSubscriptionsEligibility)) installed++;
    if (WAGRHookInstance(cls, @"isSubscriptionsRowPresentInTable", (IMP)hookIsSubscriptionsRowPresent, (IMP *)&origIsSubscriptionsRowPresent)) installed++;
    if (WAGRHookInstance(cls, @"removeSubscriptionsRow", (IMP)hookRemoveSubscriptionsRow, (IMP *)&origRemoveSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"insertSubscriptionsRow", (IMP)hookInsertSubscriptionsRow, (IMP *)&origInsertSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"addSubscriptionsRowToSection:", (IMP)hookAddSubscriptionsRowToSection, (IMP *)&origAddSubscriptionsRowToSection)) installed++;
    if (WAGRHookInstance(cls, @"getSettingsViewModel", (IMP)hookGetSettingsViewModel, (IMP *)&origGetSettingsViewModel)) installed++;
    if (WAGRHookInstance(cls, @"createSettingsEntryPointViewModel", (IMP)hookCreateSettingsEntryPointViewModel, (IMP *)&origCreateSettingsEntryPointViewModel)) installed++;

    gWAGRSettingsRowsInstalledHookCount = installed;
    gWAGRSettingsRowsHooksInstalled = installed > 0;

    if (!gWAGRSettingsRowsHooksInstalled) {
        WAGRSetLastSettingsRowsError(@"WASettingsViewController found, but none of the expected selectors were hookable");
    } else {
        WAGRSetLastSettingsRowsError(nil);
        NSLog(@"[WATweaks][NativeSettingsRows] installed %lu hooks on WASettingsViewController",
              (unsigned long)installed);
    }
}

extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) {
    return gWAGRSettingsRowsNativeRowInserted;
}

extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"attempted=%@\nhooksInstalled=%@\ninstalledHookCount=%lu\nsettingsClass=%@\nnativeRowInserted=%@\nfactoryFailed=%@\ninsertAttempts=%lu\nsubscriptionForceCount=%lu\nforceSubscriptions=%@\nforceDeveloper=%@\nlastError=%@",
            gWAGRSettingsRowsAttempted ? @"YES" : @"NO",
            gWAGRSettingsRowsHooksInstalled ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInstalledHookCount,
            NSClassFromString(@"WASettingsViewController") ? @"found" : @"missing",
            gWAGRSettingsRowsNativeRowInserted ? @"YES" : @"NO",
            gWAGRSettingsRowsFactoryFailed ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInsertAttempts,
            (unsigned long)gWAGRSettingsRowsSubscriptionForces,
            WAGRSettingsRowsShouldForceSubscriptions() ? @"YES" : @"NO",
            WAGRSettingsRowsShouldForceDeveloper() ? @"YES" : @"NO",
            gWAGRSettingsRowsLastError ?: @"none"];
}

__attribute__((constructor))
static void WAGRSettingsRowsNativeInit(void) {
    @autoreleasepool {
        NSArray<NSNumber *> *delays = @[@0.2, @1.0, @3.0, @6.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WAGRSettingsRowsNativeEnsureHooksInstalled();
            });
        }
    }
}
