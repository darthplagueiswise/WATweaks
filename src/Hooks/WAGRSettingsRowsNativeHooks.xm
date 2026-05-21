// WAGRSettingsRowsNativeHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Native WASettingsViewController integration.
//
// This file owns the Settings-list model injection. No UIKit footer-row path lives
// here: if native WATableRow insertion fails, the only fallback remains the
// existing long-press path in Tweak.x.
//
// Strategy:
//   • hook WASettingsViewController with retry;
//   • insert WATweaks as a real WATableRow inside the native WATableSection;
//   • force the Subscriptions/WA Plus row pipeline when the related gates are ON;
//   • optionally add a Developer row shim when the native provider gate is ON but
//     WhatsApp does not add its own SettingsView_DeveloperCell.
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
static BOOL gWAGRSettingsRowsFactoryFailed = NO;
static NSUInteger gWAGRSettingsRowsInstalledHookCount = 0;
static NSUInteger gWAGRSettingsRowsInsertAttempts = 0;
static NSUInteger gWAGRSettingsRowsSubscriptionForces = 0;
static NSString *gWAGRSettingsRowsLastError = nil;

static const void *kWAGRNativeWATweaksRowMarker = &kWAGRNativeWATweaksRowMarker;
static const void *kWAGRNativeDeveloperRowMarker = &kWAGRNativeDeveloperRowMarker;
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
static void (*origViewWillAppear)(id, SEL, BOOL) = NULL;

static void WAGRSetLastSettingsRowsError(NSString *error) {
    gWAGRSettingsRowsLastError = [error copy];
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

static void WAGRSettingsRowsEnsureRuntimeOwners(void) {
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
    @try { [parts addObject:[[row description] lowercaseString] ?: @""]; } @catch (__unused id ex) {}
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
            } @catch (__unused id ex) { row = nil; }
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
            } @catch (__unused id ex) { row = nil; }
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

    // Common WATableRow/UI cell knobs. Methods that do not exist are ignored.
    WAGRCallVoid1(row, @"setHandler:", handler);
    WAGRCallVoid1(row, @"setAccessoryHandler:", handler);
    WAGRCallVoidInt(row, @"setAccessoryType:", 1);
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
    if (WAGRResponds(section, @"setRows:")) { WAGRCallVoid1(section, @"setRows:", rows); return YES; }
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

static NSMutableArray *WAGRCollectCandidateSections(id settingsVC, id preferredSection) {
    NSMutableArray *sections = [NSMutableArray array];
    if (WAGRIsWATableSectionLike(preferredSection)) [sections addObject:preferredSection];

    for (NSString *ivarName in @[@"_sectionSettings", @"_subscriptionsSection", @"_bannersSection"]) {
        Ivar iv = class_getInstanceVariable([settingsVC class], ivarName.UTF8String);
        if (!iv) continue;
        id obj = object_getIvar(settingsVC, iv);
        if (WAGRIsWATableSectionLike(obj) && ![sections containsObject:obj]) [sections addObject:obj];
    }

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([settingsVC class], &count);
    for (unsigned int i = 0; i < count; i++) {
        id obj = nil;
        @try { obj = object_getIvar(settingsVC, ivars[i]); } @catch (__unused id ex) { obj = nil; }
        if (WAGRIsWATableSectionLike(obj) && ![sections containsObject:obj]) [sections addObject:obj];
    }
    if (ivars) free(ivars);
    return sections;
}

static id WAGRBestSettingsSection(id settingsVC, id preferredSection) {
    NSMutableArray *sections = WAGRCollectCandidateSections(settingsVC, preferredSection);
    if (sections.count == 0) return nil;

    for (id section in sections) {
        NSString *debug = [[WAGRRowsForSection(section) valueForKey:@"description"] componentsJoinedByString:@" "].lowercaseString ?: @"";
        if ([debug containsString:@"settingsview_dataandstorageusagecell"] ||
            [debug containsString:@"settingsview_helpcell"] ||
            [debug containsString:@"settingsview_chatscell"] ||
            [debug containsString:@"settingsview_notificationscell"]) return section;
    }
    return sections.firstObject;
}

static void WAGRReloadSettingsTable(id settingsVC) {
    id table = nil;
    if (WAGRResponds(settingsVC, @"tableView")) table = WAGRCallObj0(settingsVC, @"tableView");
    if ([table isKindOfClass:UITableView.class]) [(UITableView *)table reloadData];
}

static void WAGRInsertNativeRowsIfNeeded(id settingsVC, id preferredSection) {
    if (!settingsVC) return;
    id section = WAGRBestSettingsSection(settingsVC, preferredSection);
    if (!section) { WAGRSetLastSettingsRowsError(@"no WATableSection candidate found"); return; }

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
        Ivar sectionIvar = class_getInstanceVariable([settingsVC class], "_subscriptionsSection");
        id section = sectionIvar ? object_getIvar(settingsVC, sectionIvar) : nil;
        if (section && [settingsVC respondsToSelector:NSSelectorFromString(@"addSubscriptionsRowToSection:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(settingsVC, NSSelectorFromString(@"addSubscriptionsRowToSection:"), section);
            NSLog(@"[WATweaks][NativeSettingsRows] forced addSubscriptionsRowToSection:");
            return;
        }
        WAGRSetLastSettingsRowsError(@"could not force subscriptions row: no insert method/section available");
    });
}

static void WAGRRefreshSettingsRowsSoon(id settingsVC, id preferredSection) {
    if (!settingsVC) return;
    WAGRSettingsRowsEnsureRuntimeOwners();
    WAGRInsertNativeRowsIfNeeded(settingsVC, preferredSection);
    WAGRForceSubscriptionsRowIfNeeded(settingsVC);
}

static void hookAddStorageAndDataRow(id self, SEL _cmd, id section, id settingTypeToRow) {
    // Insert before the Storage & Data row so WATweaks lands in the desired
    // visible position: after Help/Feedback-style rows and before Storage/Data.
    WAGRInsertNativeRowsIfNeeded(self, section);
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

static void hookInsertSubscriptionsRow(id self, SEL _cmd) { if (origInsertSubscriptionsRow) origInsertSubscriptionsRow(self, _cmd); }
static void hookAddSubscriptionsRowToSection(id self, SEL _cmd, id section) { if (origAddSubscriptionsRowToSection) origAddSubscriptionsRowToSection(self, _cmd, section); }

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

static void hookViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (origViewWillAppear) origViewWillAppear(self, _cmd, animated);
    WAGRRefreshSettingsRowsSoon(self, nil);
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
    if (!cls) { WAGRSetLastSettingsRowsError(@"WASettingsViewController not loaded yet"); return; }

    NSUInteger installed = 0;
    if (WAGRHookInstance(cls, @"addStorageAndDataRowToWATableSection:settingTypeToRow:", (IMP)hookAddStorageAndDataRow, (IMP *)&origAddStorageAndDataRow)) installed++;
    if (WAGRHookInstance(cls, @"checkSubscriptionsEligibilityAndInsertRowIfNeeded", (IMP)hookCheckSubscriptionsEligibility, (IMP *)&origCheckSubscriptionsEligibility)) installed++;
    if (WAGRHookInstance(cls, @"isSubscriptionsRowPresentInTable", (IMP)hookIsSubscriptionsRowPresent, (IMP *)&origIsSubscriptionsRowPresent)) installed++;
    if (WAGRHookInstance(cls, @"removeSubscriptionsRow", (IMP)hookRemoveSubscriptionsRow, (IMP *)&origRemoveSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"insertSubscriptionsRow", (IMP)hookInsertSubscriptionsRow, (IMP *)&origInsertSubscriptionsRow)) installed++;
    if (WAGRHookInstance(cls, @"addSubscriptionsRowToSection:", (IMP)hookAddSubscriptionsRowToSection, (IMP *)&origAddSubscriptionsRowToSection)) installed++;
    if (WAGRHookInstance(cls, @"getSettingsViewModel", (IMP)hookGetSettingsViewModel, (IMP *)&origGetSettingsViewModel)) installed++;
    if (WAGRHookInstance(cls, @"createSettingsEntryPointViewModel", (IMP)hookCreateSettingsEntryPointViewModel, (IMP *)&origCreateSettingsEntryPointViewModel)) installed++;
    if (WAGRHookInstance(cls, @"viewWillAppear:", (IMP)hookViewWillAppear, (IMP *)&origViewWillAppear)) installed++;

    gWAGRSettingsRowsInstalledHookCount = installed;
    gWAGRSettingsRowsHooksInstalled = installed > 0;
    if (!gWAGRSettingsRowsHooksInstalled) WAGRSetLastSettingsRowsError(@"WASettingsViewController found, but none of the expected selectors were hookable");
    else {
        WAGRSetLastSettingsRowsError(nil);
        NSLog(@"[WATweaks][NativeSettingsRows] installed %lu hooks on WASettingsViewController", (unsigned long)installed);
    }
}

extern "C" BOOL WAGRSettingsRowsNativeDidInstallWATweaksRow(void) { return gWAGRSettingsRowsWATweaksInserted; }

extern "C" NSString *WAGRSettingsRowsNativeDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"attempted=%@\nhooksInstalled=%@\ninstalledHookCount=%lu\nsettingsClass=%@\nwatweaksRowInserted=%@\ndeveloperRowInserted=%@\nfactoryFailed=%@\ninsertAttempts=%lu\nsubscriptionForceCount=%lu\nforceSubscriptions=%@\nforceDeveloper=%@\nlastError=%@",
            gWAGRSettingsRowsAttempted ? @"YES" : @"NO",
            gWAGRSettingsRowsHooksInstalled ? @"YES" : @"NO",
            (unsigned long)gWAGRSettingsRowsInstalledHookCount,
            NSClassFromString(@"WASettingsViewController") ? @"found" : @"missing",
            gWAGRSettingsRowsWATweaksInserted ? @"YES" : @"NO",
            gWAGRSettingsRowsDeveloperInserted ? @"YES" : @"NO",
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRSettingsRowsNativeEnsureHooksInstalled();
            });
        }
    }
}
