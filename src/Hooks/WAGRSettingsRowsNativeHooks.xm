// WAGRSettingsRowsNativeHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Native WASettingsViewController integration.
//
// No startup constructor here. This file must not run broad Settings work during
// WhatsApp launch. Tweak.x calls WAGRSettingsRowsNativeEnsureHooksInstalled() and
// WAGRSettingsRowsNativeInjectIfPossible(vc) only after it sees a live
// WASettingsViewController table on screen.
//
// No UIKit footer-row fallback. If native insertion fails, long-press remains the
// only fallback path.
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
extern "C" BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);

static BOOL gWAGRSettingsRowsAttempted = NO;
static BOOL gWAGRSettingsRowsHooksInstalled = NO;
static BOOL gWAGRSettingsRowsWATweaksInserted = NO;
static BOOL gWAGRSettingsRowsDeveloperInserted = NO;
static BOOL gWAGRSettingsRowsPaymentsInserted = NO;
static BOOL gWAGRSettingsRowsFactoryFailed = NO;
static NSUInteger gWAGRSettingsRowsInstalledHookCount = 0;
static NSUInteger gWAGRSettingsRowsInsertAttempts = 0;
static NSUInteger gWAGRSettingsRowsSubscriptionForces = 0;
static NSUInteger gWAGRSettingsRowsPaymentsForces = 0;
static NSString *gWAGRSettingsRowsLastError = nil;

static const void *kWAGRNativeWATweaksRowMarker = &kWAGRNativeWATweaksRowMarker;
static const void *kWAGRNativeDeveloperRowMarker = &kWAGRNativeDeveloperRowMarker;
static const void *kWAGRNativePaymentsRowMarker = &kWAGRNativePaymentsRowMarker;
static const void *kWAGRNativeSettingsRefreshMarker = &kWAGRNativeSettingsRefreshMarker;
static const void *kWAGRNativeSettingsHandlerMarker = &kWAGRNativeSettingsHandlerMarker;

static void (*origAddStorageAndDataRow)(id, SEL, id, id) = NULL;
static void (*origCheckSubscriptionsEligibility)(id, SEL) = NULL;
static BOOL (*origIsSubscriptionsRowPresent)(id, SEL) = NULL;
static void (*origRemoveSubscriptionsRow)(id, SEL) = NULL;
static void (*origInsertSubscriptionsRow)(id, SEL) = NULL;
static void (*origAddSubscriptionsRowToSection)(id, SEL, id) = NULL;
static void (*origAddPaymentsRowToSection)(id, SEL, id) = NULL;
static id (*origCreatePaymentRowIfNeeded)(id, SEL, id) = NULL;
static BOOL (*origShowBRConsumerPaymentsHome)(id, SEL) = NULL;
static id (*origGetSettingsViewModel)(id, SEL) = NULL;
static id (*origCreateSettingsEntryPointViewModel)(id, SEL) = NULL;

static void WAGRSetLastSettingsRowsError(NSString *error) {
    gWAGRSettingsRowsLastError = [error copy];
}

static BOOL WAGRIsWASettingsVC(id obj) {
    if (!obj) return NO;
    NSString *name = NSStringFromClass([obj class]);
    return [name isEqualToString:@"WASettingsViewController"] ||
           [name containsString:@"WASettingsViewController"];
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

static void WAGRPresentDeveloperMenuFromSettings(id settingsVC) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *err = nil;
        UIViewController *host = WAGRPresenterForSettings(settingsVC) ?: WAGRTopViewController();
        BOOL ok = WAGRLaunchNativeDeveloperMenu(host, &err);
        if (!ok) NSLog(@"[WATweaks][NativeSettingsRows] Developer row launcher failed: %@", err.localizedDescription ?: @"unknown");
    });
}

static void WAGRPresentPaymentsFromSettings(id settingsVC) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([settingsVC respondsToSelector:NSSelectorFromString(@"showBRConsumerPaymentsHome")]) {
            ((void (*)(id, SEL))objc_msgSend)(settingsVC, NSSelectorFromString(@"showBRConsumerPaymentsHome"));
            return;
        }
        WAGRPresentWATweaksMenuFromSettings(settingsVC);
    });
}

static BOOL WAGRResponds(id obj, NSString *selectorName) {
    return obj && [obj respondsToSelector:NSSelectorFromString(selectorName)];
}

static id WAGRCallObj0(id obj, NSString *selectorName) {
    if (!WAGRResponds(obj, selectorName)) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static void WAGRCallVoid1(id obj, NSString *selectorName, id arg) {
    if (!WAGRResponds(obj, selectorName)) return;
    SEL sel = NSSelectorFromString(selectorName);
    ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

static void WAGRCallVoidInt(id obj, NSString *selectorName, NSInteger value) {
    if (!WAGRResponds(obj, selectorName)) return;
    SEL sel = NSSelectorFromString(selectorName);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(obj, sel, value);
}

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
        @"isEligibleForSubscriptions",
        @"isSubscribedToAiBenefit",
        @"isAISubscriptionEnabled"
    ]);
}

static BOOL WAGRSettingsRowsShouldForceDeveloper(void) {
    if (WAGRPref(@"wagr.settingsrows.force_developer")) return YES;
    if (WAGRPref(kWAGRDebugMenuNative) || WAGRPref(kWAGRInternalMaster) ||
        WAGRPref(kWAGREmployeeMaster)  || WAGRPref(kWAGRDebugMode)) return YES;

    NSString *allowedKey = WAGROverrideKey(nil, @"_TtC15WADebugMenuMain17DebugMenuProvider", NO, @"isDebugMenuAllowed");
    NSString *shortcutKey = WAGROverrideKey(nil, @"_TtC15WADebugMenuMain17DebugMenuProvider", NO, @"isDebugMenuShortcutEnabled");
    if ((WAGRHasOverride(allowedKey) && WAGROverrideBool(allowedKey)) ||
        (WAGRHasOverride(shortcutKey) && WAGROverrideBool(shortcutKey))) return YES;

    return WAGRWAABAnyOn(@[
        @"sections_in_help_menu",
        @"mobile_config_debug_internal",
        @"dogfooder_diagnostics",
        @"ios_internal_hall_enabled",
        @"is_internal_tester"
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
        @"br_payments_pix_native_enabled"
    ]);
}

static void WAGRSettingsRowsEnsureRuntimeOwners(void) {
    // Settings-only path. Do not call this from startup.
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRReinstallPersistedHooks();
}

static NSString *WAGRRowDebugString(id row) {
    if (!row) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (NSString *selName in @[@"identifier", @"accessibilityIdentifier", @"title", @"name", @"text", @"cellText"]) {
        @try {
            id value = WAGRCallObj0(row, selName);
            if ([value isKindOfClass:NSString.class] && [value length]) [parts addObject:[value lowercaseString]];
        } @catch (__unused id ex) {}
    }

    @try {
        NSString *desc = [[row description] lowercaseString];
        if (desc.length) [parts addObject:desc];
    } @catch (__unused id ex) {}

    return [parts componentsJoinedByString:@" "];
}

static BOOL WAGRRowLooksLike(id row, NSString *needle) {
    if (!row || !needle.length) return NO;
    return [WAGRRowDebugString(row) containsString:needle.lowercaseString];
}

static NSArray *WAGRRowsForSection(id section) {
    id rows = WAGRCallObj0(section, @"rows");
    return [rows isKindOfClass:NSArray.class] ? rows : nil;
}

static BOOL WAGRSectionAlreadyHasRow(id section, NSString *identifierNeedle) {
    for (id row in WAGRRowsForSection(section)) {
        if (WAGRRowLooksLike(row, identifierNeedle)) return YES;
    }
    return NO;
}

static id WAGRCreateNativeRow(id settingsVC, NSString *identifier, NSString *title, NSString *subtitle, NSString *imageName, dispatch_block_t tapBlock) {
    if (!settingsVC || !identifier.length) return nil;

    id handler = [^(__unused id row, __unused id cell) {
        if (tapBlock) tapBlock();
    } copy];

    objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsHandlerMarker, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id row = nil;
    SEL factory = NSSelectorFromString(@"tableRowWithIdentifier:type:handler:");
    if ([settingsVC respondsToSelector:factory]) {
        for (NSNumber *n in @[@0,@1,@2,@3,@4,@5,@6,@7,@8,@9,@10,@11,@12]) {
            @try {
                row = ((id (*)(id, SEL, NSString *, NSInteger, id))objc_msgSend)(settingsVC, factory, identifier, n.integerValue, handler);
            } @catch (__unused id ex) {
                row = nil;
            }
            if (row) break;
        }
    }

    if (!row) {
        Class rowClass = NSClassFromString(@"WATableRow");
        if (rowClass) {
            @try {
                id alloc = [rowClass alloc];
                if ([alloc respondsToSelector:NSSelectorFromString(@"initWithIdentifier:type:")]) {
                    row = ((id (*)(id, SEL, NSString *, NSInteger))objc_msgSend)(alloc, NSSelectorFromString(@"initWithIdentifier:type:"), identifier, 0);
                } else if ([alloc respondsToSelector:NSSelectorFromString(@"initWithIdentifier:")]) {
                    row = ((id (*)(id, SEL, NSString *))objc_msgSend)(alloc, NSSelectorFromString(@"initWithIdentifier:"), identifier);
                }
            } @catch (__unused id ex) {
                row = nil;
            }
        }
    }

    if (!row) {
        gWAGRSettingsRowsFactoryFailed = YES;
        WAGRSetLastSettingsRowsError(@"could not create WATableRow via WASettingsViewController factory or WATableRow init");
        return nil;
    }

    NSDictionary<NSString *, id> *stringValues = @{
        @"setIdentifier:": identifier,
        @"setAccessibilityIdentifier:": identifier,
        @"setAccessibilityLabel:": title ?: identifier,
        @"setTitle:": title ?: identifier,
        @"setName:": title ?: identifier,
        @"setText:": title ?: identifier,
        @"setCellText:": title ?: identifier,
        @"setDisplayName:": title ?: identifier,
        @"setSubtitle:": subtitle ?: @"",
        @"setDetailText:": subtitle ?: @"",
        @"setCellDetailText:": subtitle ?: @""
    };
    for (NSString *selName in stringValues) WAGRCallVoid1(row, selName, stringValues[selName]);

    WAGRCallVoid1(row, @"setHandler:", handler);
    WAGRCallVoid1(row, @"setAccessoryHandler:", handler);
    WAGRCallVoidInt(row, @"setAccessoryType:", UITableViewCellAccessoryDisclosureIndicator);
    WAGRCallVoidInt(row, @"setCellAccessoryType:", UITableViewCellAccessoryDisclosureIndicator);

    UIImage *icon = nil;
    if (imageName.length) icon = [UIImage systemImageNamed:imageName];
    if (!icon) icon = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
    if (!icon) icon = [UIImage systemImageNamed:@"curlybraces"];
    if (icon) {
        WAGRCallVoid1(row, @"setImage:", icon);
        WAGRCallVoid1(row, @"setIcon:", icon);
        WAGRCallVoid1(row, @"setCellImage:", icon);
    }

    return row;
}

static BOOL WAGRSetRowsOnSection(id section, NSArray *rows) {
    if (!section || !rows) return NO;
    if (WAGRResponds(section, @"setRows:")) {
        WAGRCallVoid1(section, @"setRows:", rows);
        return YES;
    }
    return NO;
}

static BOOL WAGRAddRowToSection(id section, id row, NSString *beforeNeedle) {
    if (!section || !row) return NO;

    NSArray *existing = WAGRRowsForSection(section);
    if (existing.count > 0 && WAGRResponds(section, @"setRows:")) {
        NSMutableArray *newRows = [existing mutableCopy];
        NSUInteger idx = NSNotFound;

        if (beforeNeedle.length) {
            for (NSUInteger i = 0; i < newRows.count; i++) {
                if (WAGRRowLooksLike(newRows[i], beforeNeedle)) { idx = i; break; }
            }
        }

        if (idx == NSNotFound) idx = newRows.count;
        [newRows insertObject:row atIndex:idx];
        return WAGRSetRowsOnSection(section, newRows);
    }

    for (NSString *selName in @[@"addRow:", @"appendRow:", @"addTableRow:", @"addObject:"]) {
        if (!WAGRResponds(section, selName)) continue;
        WAGRCallVoid1(section, selName, row);
        return YES;
    }

    WAGRSetLastSettingsRowsError([NSString stringWithFormat:@"section %@ has no known row mutator", NSStringFromClass([section class])]);
    return NO;
}

static BOOL WAGRIsWATableSectionLike(id obj) {
    if (!obj) return NO;
    NSString *cls = NSStringFromClass([obj class]);
    return [cls containsString:@"WATableSection"] || WAGRResponds(obj, @"addRow:") || WAGRResponds(obj, @"rows");
}

static void WAGRAddSectionCandidate(NSMutableArray *sections, id obj) {
    if (!obj) return;

    if ([obj isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)obj) WAGRAddSectionCandidate(sections, item);
        return;
    }

    if (WAGRIsWATableSectionLike(obj) && ![sections containsObject:obj]) {
        [sections addObject:obj];
    }
}

static id WAGRObjectIvarIfSafe(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    Ivar iv = class_getInstanceVariable([obj class], ivarName);
    if (!iv) return nil;

    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return nil; // never object_getIvar primitive / Swift value ivars

    id value = nil;
    @try {
        value = object_getIvar(obj, iv);
    } @catch (__unused id ex) {
        value = nil;
    }
    return value;
}

static NSMutableArray *WAGRCollectCandidateSections(id settingsVC, id preferredSection) {
    NSMutableArray *sections = [NSMutableArray array];
    WAGRAddSectionCandidate(sections, preferredSection);

    for (NSString *ivarName in @[@"_sectionSettings", @"_subscriptionsSection", @"_bannersSection"]) {
        WAGRAddSectionCandidate(sections, WAGRObjectIvarIfSafe(settingsVC, ivarName.UTF8String));
    }

    return sections;
}

static id WAGRBestSettingsSection(id settingsVC, id preferredSection) {
    NSMutableArray *sections = WAGRCollectCandidateSections(settingsVC, preferredSection);
    if (sections.count == 0) return nil;

    for (id section in sections) {
        NSMutableArray<NSString *> *rowDebug = [NSMutableArray array];
        for (id row in WAGRRowsForSection(section)) [rowDebug addObject:WAGRRowDebugString(row)];
        NSString *debug = [rowDebug componentsJoinedByString:@" "];

        if ([debug containsString:@"settingsview_dataandstorageusagecell"] ||
            [debug containsString:@"settingsview_helpcell"] ||
            [debug containsString:@"settingsview_chatscell"] ||
            [debug containsString:@"settingsview_notificationscell"]) {
            return section;
        }
    }

    return sections.firstObject;
}

static void WAGRReloadSettingsTable(id settingsVC) {
    id table = WAGRCallObj0(settingsVC, @"tableView");
    if ([table isKindOfClass:UITableView.class]) [(UITableView *)table reloadData];
}

extern "C" void WAGRSettingsRowsNativeInjectIfPossible(id maybeSettingsVC) {
    if (!WAGRIsWASettingsVC(maybeSettingsVC)) return;

    id settingsVC = maybeSettingsVC;
    id section = WAGRBestSettingsSection(settingsVC, nil);
    if (!section) {
        WAGRSetLastSettingsRowsError(@"no WATableSection candidate found");
        return;
    }

    gWAGRSettingsRowsInsertAttempts++;

    if (![objc_getAssociatedObject(section, kWAGRNativeWATweaksRowMarker) boolValue] &&
        !WAGRSectionAlreadyHasRow(section, @"settingsview_watweakscell")) {
        id row = WAGRCreateNativeRow(settingsVC,
                                     @"SettingsView_WATweaksCell",
                                     @"WATweaks",
                                     @"Runtime flags, hidden Settings rows and diagnostics",
                                     @"chevron.left.forwardslash.chevron.right",
                                     ^{ WAGRPresentWATweaksMenuFromSettings(settingsVC); });

        if (row && WAGRAddRowToSection(section, row, @"settingsview_dataandstorageusagecell")) {
            objc_setAssociatedObject(section, kWAGRNativeWATweaksRowMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            gWAGRSettingsRowsWATweaksInserted = YES;
            gWAGRSettingsRowsFactoryFailed = NO;
            WAGRSetLastSettingsRowsError(nil);
            NSLog(@"[WATweaks][NativeSettingsRows] inserted SettingsView_WATweaksCell into %@", NSStringFromClass([section class]));
        }
    }

    if (WAGRSettingsRowsShouldForcePayments() &&
        ![objc_getAssociatedObject(section, kWAGRNativePaymentsRowMarker) boolValue] &&
        !WAGRSectionAlreadyHasRow(section, @"settingsview_paymentscell")) {
        id row = WAGRCreateNativeRow(settingsVC,
                                     @"SettingsView_PaymentsCell",
                                     @"Payments",
                                     @"Payments, PIX/UPI and payment settings surfaces",
                                     @"creditcard.fill",
                                     ^{ WAGRPresentPaymentsFromSettings(settingsVC); });

        if (row && WAGRAddRowToSection(section, row, @"settingsview_dataandstorageusagecell")) {
            objc_setAssociatedObject(section, kWAGRNativePaymentsRowMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            gWAGRSettingsRowsPaymentsInserted = YES;
            NSLog(@"[WATweaks][NativeSettingsRows] inserted SettingsView_PaymentsCell shim into %@", NSStringFromClass([section class]));
        }
    }

    if (WAGRSettingsRowsShouldForceDeveloper() &&
        ![objc_getAssociatedObject(section, kWAGRNativeDeveloperRowMarker) boolValue] &&
        !WAGRSectionAlreadyHasRow(section, @"settingsview_developercell")) {
        id row = WAGRCreateNativeRow(settingsVC,
                                     @"SettingsView_DeveloperCell",
                                     @"Developer",
                                     @"WhatsApp native developer menu",
                                     @"chevron.left.forwardslash.chevron.right",
                                     ^{ WAGRPresentDeveloperMenuFromSettings(settingsVC); });

        if (row && WAGRAddRowToSection(section, row, @"settingsview_dataandstorageusagecell")) {
            objc_setAssociatedObject(section, kWAGRNativeDeveloperRowMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            gWAGRSettingsRowsDeveloperInserted = YES;
            NSLog(@"[WATweaks][NativeSettingsRows] inserted SettingsView_DeveloperCell shim into %@", NSStringFromClass([section class]));
        }
    }

    WAGRReloadSettingsTable(settingsVC);
}

static void WAGRForcePaymentsRowIfNeeded(id settingsVC) {
    if (!settingsVC || !WAGRSettingsRowsShouldForcePayments()) return;
    gWAGRSettingsRowsPaymentsForces++;
    if ([settingsVC respondsToSelector:NSSelectorFromString(@"addPaymentsRowToSection:")]) {
        id section = WAGRBestSettingsSection(settingsVC, nil);
        if (section) ((void (*)(id, SEL, id))objc_msgSend)(settingsVC, NSSelectorFromString(@"addPaymentsRowToSection:"), section);
    }
}

static BOOL WAGROrigSubscriptionsRowPresent(id self) {
    if (origIsSubscriptionsRowPresent) return origIsSubscriptionsRowPresent(self, NSSelectorFromString(@"isSubscriptionsRowPresentInTable"));
    return NO;
}

static void WAGRForceSubscriptionsRowIfNeeded(id settingsVC) {
    if (!settingsVC || !WAGRSettingsRowsShouldForceSubscriptions()) return;
    if ([objc_getAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker) boolValue]) return;

    objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(settingsVC, kWAGRNativeSettingsRefreshMarker, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (WAGROrigSubscriptionsRowPresent(settingsVC)) return;

        gWAGRSettingsRowsSubscriptionForces++;

        if ([settingsVC respondsToSelector:NSSelectorFromString(@"insertSubscriptionsRow")]) {
            ((void (*)(id, SEL))objc_msgSend)(settingsVC, NSSelectorFromString(@"insertSubscriptionsRow"));
            NSLog(@"[WATweaks][NativeSettingsRows] forced insertSubscriptionsRow");
            return;
        }

        id section = WAGRObjectIvarIfSafe(settingsVC, "_subscriptionsSection");
        if (section && [settingsVC respondsToSelector:NSSelectorFromString(@"addSubscriptionsRowToSection:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(settingsVC, NSSelectorFromString(@"addSubscriptionsRowToSection:"), section);
            NSLog(@"[WATweaks][NativeSettingsRows] forced addSubscriptionsRowToSection:");
            return;
        }

        WAGRSetLastSettingsRowsError(@"could not force subscriptions row: no insert method/section available");
    });
}

static void WAGRRefreshSettingsRowsSoon(id settingsVC, id preferredSection) {
    if (!WAGRIsWASettingsVC(settingsVC)) return;
    WAGRSettingsRowsEnsureRuntimeOwners();
    if (preferredSection) {
        // During builder-time we know the exact section. Use it immediately.
        NSMutableArray *sections = WAGRCollectCandidateSections(settingsVC, preferredSection);
        if (sections.count) {
            id best = WAGRBestSettingsSection(settingsVC, preferredSection);
            if (best) {
                // Reuse the public injection after associating the preferred section through the normal collector.
                (void)best;
            }
        }
    }
    WAGRSettingsRowsNativeInjectIfPossible(settingsVC);
    WAGRForcePaymentsRowIfNeeded(settingsVC);
    WAGRForceSubscriptionsRowIfNeeded(settingsVC);
}

static void hookAddStorageAndDataRow(id self, SEL _cmd, id section, id settingTypeToRow) {
    // Insert before the Storage & Data row so WATweaks lands in the desired area.
    if (WAGRIsWASettingsVC(self)) {
        id best = section ?: WAGRBestSettingsSection(self, nil);
        if (best) {
            gWAGRSettingsRowsInsertAttempts++;
            if (![objc_getAssociatedObject(best, kWAGRNativeWATweaksRowMarker) boolValue] &&
                !WAGRSectionAlreadyHasRow(best, @"settingsview_watweakscell")) {
                id row = WAGRCreateNativeRow(self,
                                             @"SettingsView_WATweaksCell",
                                             @"WATweaks",
                                             @"Runtime flags, hidden Settings rows and diagnostics",
                                             @"chevron.left.forwardslash.chevron.right",
                                             ^{ WAGRPresentWATweaksMenuFromSettings(self); });
                if (row && WAGRAddRowToSection(best, row, @"settingsview_dataandstorageusagecell")) {
                    objc_setAssociatedObject(best, kWAGRNativeWATweaksRowMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    gWAGRSettingsRowsWATweaksInserted = YES;
                }
            }
        }
    }

    if (origAddStorageAndDataRow) origAddStorageAndDataRow(self, _cmd, section, settingTypeToRow);
    WAGRRefreshSettingsRowsSoon(self, section);
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

static void hookAddPaymentsRowToSection(id self, SEL _cmd, id section) {
    if (origAddPaymentsRowToSection) origAddPaymentsRowToSection(self, _cmd, section);
}

static id hookCreatePaymentRowIfNeeded(id self, SEL _cmd, id arg) {
    if (origCreatePaymentRowIfNeeded) return origCreatePaymentRowIfNeeded(self, _cmd, arg);
    return nil;
}

static BOOL hookShowBRConsumerPaymentsHome(id self, SEL _cmd) {
    if (origShowBRConsumerPaymentsHome) return origShowBRConsumerPaymentsHome(self, _cmd);
    return NO;
}

static id hookGetSettingsViewModel(id self, SEL _cmd) {
    id result = origGetSettingsViewModel ? origGetSettingsViewModel(self, _cmd) : nil;
    WAGRRefreshSettingsRowsSoon(self, nil);
    return result;
}

static id hookCreateSettingsEntryPointViewModel(id self, SEL _cmd) {
    id result = origCreateSettingsEntryPointViewModel ? origCreateSettingsEntryPointViewModel(self, _cmd) : nil;
    WAGRRefreshSettingsRowsSoon(self, nil);
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
    if (WAGRHookInstance(cls, @"addStorageAndDataRowToWATableSection:settingTypeToRow:", (IMP)hookAddStorageAndDataRow, (IMP *)&origAddStorageAndDataRow)) installed++;
    if (WAGRHookInstance(cls, @"checkSubscriptionsEligibilityAndInsertRowIfNeeded", (IMP)hookCheckSubscriptionsEligibility, (IMP *)&origCheckSubscriptionsEligibility)) installed++;
    if (WAGRHookInstance(cls, @"isSubscriptionsRowPresentInTable", (IMP)hookIsSubscriptionsRowPresent, (IMP *)&origIsSubscriptionsRowPresent)) installed++;
    if (WAGRHookInstance(cls, @"removeSubscriptionsRow", (IMP)hookRemoveSubscriptionsRow, (IMP *)&origRemoveSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"insertSubscriptionsRow", (IMP)hookInsertSubscriptionsRow, (IMP *)&origInsertSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"addSubscriptionsRowToSection:", (IMP)hookAddSubscriptionsRowToSection, (IMP *)&origAddSubscriptionsRowToSection)) installed++;
    if (WAGRHookInstance(cls, @"addPaymentsRowToSection:", (IMP)hookAddPaymentsRowToSection, (IMP *)&origAddPaymentsRowToSection)) installed++;
    if (WAGRHookInstance(cls, @"createPaymentRowIfNeeded:", (IMP)hookCreatePaymentRowIfNeeded, (IMP *)&origCreatePaymentRowIfNeeded)) installed++;
    if (WAGRHookInstance(cls, @"showBRConsumerPaymentsHome", (IMP)hookShowBRConsumerPaymentsHome, (IMP *)&origShowBRConsumerPaymentsHome)) installed++;
    if (WAGRHookInstance(cls, @"getSettingsViewModel", (IMP)hookGetSettingsViewModel, (IMP *)&origGetSettingsViewModel)) installed++;
    if (WAGRHookInstance(cls, @"createSettingsEntryPointViewModel", (IMP)hookCreateSettingsEntryPointViewModel, (IMP *)&origCreateSettingsEntryPointViewModel)) installed++;

    gWAGRSettingsRowsInstalledHookCount = installed;
    gWAGRSettingsRowsHooksInstalled = installed > 0;

    if (!gWAGRSettingsRowsHooksInstalled) {
        WAGRSetLastSettingsRowsError(@"WASettingsViewController found, but none of the expected selectors were hookable");
    } else {
        WAGRSetLastSettingsRowsError(nil);
        NSLog(@"[WATweaks][NativeSettingsRows] installed %lu hooks on WASettingsViewController", (unsigned long)installed);
    }
}

extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) {
    return gWAGRSettingsRowsWATweaksInserted;
}

extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"attempted=%@\nhooksInstalled=%@\ninstalledHookCount=%lu\nsettingsClass=%@\nwatweaksRowInserted=%@\ndeveloperRowInserted=%@\nfactoryFailed=%@\ninsertAttempts=%lu\nsubscriptionForceCount=%lu\nforceSubscriptions=%@\nforceDeveloper=%@\nlastError=%@",
            gWAGRSettingsRowsAttempted ? @"YES" : @"NO",
            gWAGRSettingsRowsHooksInstalled ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInstalledHookCount,
            NSClassFromString(@"WASettingsViewController") ? @"found" : @"missing",
            gWAGRSettingsRowsWATweaksInserted ? @"YES" : @"NO",
            gWAGRSettingsRowsDeveloperInserted ? @"YES" : @"NO",
            gWAGRSettingsRowsPaymentsInserted ? @"YES" : @"NO",
            gWAGRSettingsRowsFactoryFailed ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInsertAttempts,
            (unsigned long)gWAGRSettingsRowsSubscriptionForces,
            (unsigned long)gWAGRSettingsRowsPaymentsForces,
            WAGRSettingsRowsShouldForceSubscriptions() ? @"YES" : @"NO",
            WAGRSettingsRowsShouldForcePayments() ? @"YES" : @"NO",
            WAGRSettingsRowsShouldForceDeveloper() ? @"YES" : @"NO",
            gWAGRSettingsRowsLastError ?: @"none"];
}
