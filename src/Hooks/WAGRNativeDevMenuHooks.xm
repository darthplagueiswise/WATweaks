// WAGRNativeDevMenuHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Native WhatsApp Debug Menu gate owner.
//
// Target confirmed from WhatsApp(10):
//   _TtC15WADebugMenuMain17DebugMenuProvider
//     -isDebugMenuAllowed
//     -isDebugMenuShortcutEnabled
//     -debugViewController
//     -presentDebugControllerIfNeeded
//
// This file does not create a fake WAAB menu. It only unlocks the native
// provider/controller path and primes the WAAB/private-experimentation gates
// through WAGRGateStore when the user asks to open the native menu.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

extern "C" void WAGRGateHooksEnsureInstalled(void);
extern "C" BOOL WAGRLaunchNativePrivateExperimentation(UIViewController *fromVC, NSError **outError);

// ── Original IMPs ────────────────────────────────────────────────────────────
typedef BOOL (*BoolIMP)(id, SEL);
static BoolIMP orig_dmAllowed = NULL;
static BoolIMP orig_dmShortcutEnabled = NULL;
static BoolIMP orig_serverPropsDisableExperimental = NULL;

static BOOL gDevMenuHooked  = NO;
static BOOL gShortcutHooked = NO;
static BOOL gServerPropsDisableExperimentalHooked = NO;
static BOOL gDebugCreateSectionsHooked = NO;
static void (*orig_debugCreateSections)(id, SEL) = NULL;
typedef NSInteger (*WAGRRowsIMP)(id, SEL, UITableView *, NSInteger);
typedef UITableViewCell *(*WAGRCellIMP)(id, SEL, UITableView *, NSIndexPath *);
typedef void (*WAGRSelectIMP)(id, SEL, UITableView *, NSIndexPath *);
static WAGRRowsIMP orig_debugRows = NULL;
static WAGRCellIMP orig_debugCell = NULL;
static WAGRSelectIMP orig_debugSelect = NULL;
static BOOL gDebugTableRowsHooked = NO;
static BOOL gDebugTableCellHooked = NO;
static BOOL gDebugTableSelectHooked = NO;
static const char *kWAGRDebugABPropsInjectedKey = "watweaks.debug.abprops.injected";

static BOOL WAGRGateForcedOn(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && WAGRGateGet(selectorName);
}

static BOOL WAGRGateForcedOff(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && !WAGRGateGet(selectorName);
}

// Called by the launcher before opening native UI. This is intentionally not
// called from constructor: it writes prefs and installs optional hooks only on
// explicit user action.
extern "C" void WAGRNativeDebugActivateSupportGates(void) {
    WAGRGateSet(@"isDebugMenuAllowed", YES);
    WAGRGateSet(@"isDebugMenuShortcutEnabled", YES);

    WAGRGateSet(@"waios_mc_debug_ui_enabled", YES);
    WAGRGateSet(@"whatsbroken_enabled", YES);
    WAGRGateSet(@"private_abprop_for_dev_only", YES);
    WAGRGateSet(@"private_experimentation_should_sync", YES);
    WAGRGateSet(@"dogfooding_nudge_settings_entrypoint_enabled", YES);

    // isDebugMenuAllowed references this gate in the binary. This must be OFF.
    WAGRGateSet(@"serverPropsDisableExperimental", NO);

    WAGRGateHooksEnsureInstalled();
}

static BOOL WAGRNativeDevAllowed(void) {
    if (WAGRPref(kWAGRDebugMenuNative) ||
        WAGRPref(kWAGRInternalMaster) ||
        WAGRPref(kWAGREmployeeMaster) ||
        WAGRPref(kWAGRDebugMode)) {
        return YES;
    }

    return WAGRGateForcedOn(@"isDebugMenuAllowed") ||
           WAGRGateForcedOn(@"isDebugMenuShortcutEnabled") ||
           WAGRGateForcedOn(@"waios_mc_debug_ui_enabled") ||
           WAGRGateForcedOn(@"private_abprop_for_dev_only");
}

static BOOL hookDevAllowed(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmAllowed ? orig_dmAllowed(self, _cmd) : NO;
}

static BOOL hookDevShortcut(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmShortcutEnabled ? orig_dmShortcutEnabled(self, _cmd) : NO;
}

static BOOL hookServerPropsDisableExperimental(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed() || WAGRGateForcedOff(@"serverPropsDisableExperimental")) return NO;
    return orig_serverPropsDisableExperimental ? orig_serverPropsDisableExperimental(self, _cmd) : NO;
}


static id WAGRMsg0(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (__unused NSException *ex) { return nil; }
}

static void WAGRMsg1Void(id obj, SEL sel, id arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg); }
    @catch (__unused NSException *ex) {}
}

static id WAGRMsg1ID(id obj, SEL sel, id arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg); }
    @catch (__unused NSException *ex) { return nil; }
}

static id WAGRMsg1NSInteger(id obj, SEL sel, NSInteger arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL, NSInteger))objc_msgSend)(obj, sel, arg); }
    @catch (__unused NSException *ex) { return nil; }
}

static void WAGRPresentNativePrivateExperimentationFrom(id debugVC) {
    NSError *err = nil;
    if (![debugVC isKindOfClass:UIViewController.class]) return;
    if (!WAGRLaunchNativePrivateExperimentation((UIViewController *)debugVC, &err)) {
        NSLog(@"[WATweaks][NativeDevMenu] Private Experimentation launch failed from AB Props row: %@", err.localizedDescription ?: @"unknown");
    }
}

static id WAGRCreateDebugRow(id section, NSString *title, dispatch_block_t action) {
    if (!section || !title.length || !action) return nil;

    id row = nil;
    SEL addDefaultSel = NSSelectorFromString(@"addDefaultTableRow");
    SEL addStyleSel = NSSelectorFromString(@"addTableRowWithCellStyle:");
    if ([section respondsToSelector:addDefaultSel]) {
        row = WAGRMsg0(section, addDefaultSel);
    }
    if (!row && [section respondsToSelector:addStyleSel]) {
        row = WAGRMsg1NSInteger(section, addStyleSel, UITableViewCellStyleDefault);
    }
    if (!row) return nil;

    id cell = WAGRMsg0(row, NSSelectorFromString(@"cell"));
    if ([cell isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *tvCell = (UITableViewCell *)cell;
        tvCell.textLabel.text = title;
        tvCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        tvCell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    id handler = [^{ action(); } copy];
    WAGRMsg1Void(row, NSSelectorFromString(@"setHandler:"), handler);
    return row;
}

static id WAGRDebugABPropsSection(id debugVC) {
    id targetSection = nil;
    id sections = WAGRMsg0(debugVC, NSSelectorFromString(@"sections"));
    if ([sections isKindOfClass:NSArray.class]) {
        for (id section in (NSArray *)sections) {
            id header = WAGRMsg0(section, NSSelectorFromString(@"headerText"));
            if ([header isKindOfClass:NSString.class] && [(NSString *)header rangeOfString:@"AB Props" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                targetSection = section;
                break;
            }
        }
    }

    if (!targetSection && [debugVC respondsToSelector:NSSelectorFromString(@"addSection")]) {
        targetSection = WAGRMsg0(debugVC, NSSelectorFromString(@"addSection"));
        WAGRMsg1Void(targetSection, NSSelectorFromString(@"setHeaderText:"), @"AB Props");
    }
    return targetSection;
}

static void WAGRReplaceABPropsReleaseCandidatePlaceholder(id debugVC) {
    if (!debugVC || objc_getAssociatedObject(debugVC, kWAGRDebugABPropsInjectedKey)) return;
    if (![NSStringFromClass([debugVC class]) isEqualToString:@"WADebugViewController"]) return;

    id section = WAGRDebugABPropsSection(debugVC);
    if (!section) return;

    // This is deliberately not a fake WAAB browser. It only replaces the
    // release-candidate placeholder with rows that open WhatsApp's own native
    // Private Experimentation / AB Props debug UI, which was confirmed in the
    // executable as _TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController.
    WAGRMsg1Void(section, NSSelectorFromString(@"setRows:"), [NSMutableArray array]);

    __unsafe_unretained id weakDebugVC = debugVC;
    WAGRCreateDebugRow(section, @"Allocated AB Props", ^{
        WAGRNativeDebugActivateSupportGates();
        WAGRPresentNativePrivateExperimentationFrom(weakDebugVC);
    });
    WAGRCreateDebugRow(section, @"Private Experimentation Debug", ^{
        WAGRNativeDebugActivateSupportGates();
        WAGRPresentNativePrivateExperimentationFrom(weakDebugVC);
    });

    objc_setAssociatedObject(debugVC, kWAGRDebugABPropsInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void hookDebugCreateSections(id self, SEL _cmd) {
    if (orig_debugCreateSections) orig_debugCreateSections(self, _cmd);
    WAGRReplaceABPropsReleaseCandidatePlaceholder(self);
}


static BOOL WAGRIsDebugABPropsIndexPath(NSIndexPath *indexPath) {
    return indexPath && indexPath.section == 0 && (indexPath.row == 0 || indexPath.row == 1);
}

static UITableViewCell *WAGRNativeABPropsCell(UITableView *tableView, NSIndexPath *indexPath) {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRNativeABPropsCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRNativeABPropsCell"];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    if (indexPath.row == 0) {
        cell.textLabel.text = @"Allocated AB Props";
        cell.detailTextLabel.text = @"Open WhatsApp's native Private Experimentation AB Props tools";
    } else {
        cell.textLabel.text = @"Private Experimentation Debug";
        cell.detailTextLabel.text = @"Fetch, sync and inspect private experiment configs";
    }
    return cell;
}

static NSInteger hookDebugRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger original = orig_debugRows ? orig_debugRows(self, _cmd, tableView, section) : 0;
    if (section == 0 && WAGRNativeDevAllowed()) {
        // Flex confirmed section 0 is the AB Props release-candidate placeholder.
        // Replace its single yellow warning row with two native navigation rows.
        return MAX(original, (NSInteger)2);
    }
    return original;
}

static UITableViewCell *hookDebugCell(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (WAGRNativeDevAllowed() && WAGRIsDebugABPropsIndexPath(indexPath)) {
        return WAGRNativeABPropsCell(tableView, indexPath);
    }
    return orig_debugCell ? orig_debugCell(self, _cmd, tableView, indexPath) : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

static void hookDebugSelect(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (WAGRNativeDevAllowed() && WAGRIsDebugABPropsIndexPath(indexPath)) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        WAGRNativeDebugActivateSupportGates();
        WAGRPresentNativePrivateExperimentationFrom(self);
        return;
    }
    if (orig_debugSelect) orig_debugSelect(self, _cmd, tableView, indexPath);
}

static BOOL classHasInstanceMethod(Class cls, SEL sel) {
    return cls && sel && class_getInstanceMethod(cls, sel) != NULL;
}

static BOOL classHasClassMethod(Class cls, SEL sel) {
    return cls && sel && class_getClassMethod(cls, sel) != NULL;
}

static BOOL WAGRHookBoolNoArg(Class cls, SEL sel, BOOL classMethod, IMP replacement, BoolIMP *origOut) {
    if (!cls || !sel || !replacement || !origOut) return NO;
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'B' && ret[0] != 'c') return NO;
    Class target = classMethod ? object_getClass(cls) : cls;
    IMP orig = NULL;
    MSHookMessageEx(target, sel, replacement, &orig);
    if (!orig) return NO;
    *origOut = (BoolIMP)orig;
    return YES;
}

static void installNativeDevMenuHooks(void) {
    NSArray *providerCandidates = @[
        @"_TtC15WADebugMenuMain17DebugMenuProvider",
        @"WASettingsViewController",
        @"WASettingsTableViewController",
        @"WANewSettingsViewController",
        @"WASettingsNavTableViewController",
        @"WASettingsNavigationController",
    ];

    SEL allowedSel  = NSSelectorFromString(@"isDebugMenuAllowed");
    SEL shortcutSel = NSSelectorFromString(@"isDebugMenuShortcutEnabled");

    for (NSString *n in providerCandidates) {
        Class cls = NSClassFromString(n);
        if (!cls) continue;

        if (!gDevMenuHooked) {
            if (classHasInstanceMethod(cls, allowedSel)) {
                gDevMenuHooked = WAGRHookBoolNoArg(cls, allowedSel, NO, (IMP)hookDevAllowed, &orig_dmAllowed);
            } else if (classHasClassMethod(cls, allowedSel)) {
                gDevMenuHooked = WAGRHookBoolNoArg(cls, allowedSel, YES, (IMP)hookDevAllowed, &orig_dmAllowed);
            }
        }

        if (!gShortcutHooked) {
            if (classHasInstanceMethod(cls, shortcutSel)) {
                gShortcutHooked = WAGRHookBoolNoArg(cls, shortcutSel, NO, (IMP)hookDevShortcut, &orig_dmShortcutEnabled);
            } else if (classHasClassMethod(cls, shortcutSel)) {
                gShortcutHooked = WAGRHookBoolNoArg(cls, shortcutSel, YES, (IMP)hookDevShortcut, &orig_dmShortcutEnabled);
            }
        }

        if (gDevMenuHooked && gShortcutHooked) break;
    }

    if (!gServerPropsDisableExperimentalHooked) {
        SEL offSel = NSSelectorFromString(@"serverPropsDisableExperimental");
        for (NSString *n in @[ @"WAServerProperties", @"WAABProperties", @"FOAWAABPropertiesImpl" ]) {
            Class cls = NSClassFromString(n);
            if (!cls) continue;
            if (classHasClassMethod(cls, offSel)) {
                gServerPropsDisableExperimentalHooked = WAGRHookBoolNoArg(cls, offSel, YES, (IMP)hookServerPropsDisableExperimental, &orig_serverPropsDisableExperimental);
            } else if (classHasInstanceMethod(cls, offSel)) {
                gServerPropsDisableExperimentalHooked = WAGRHookBoolNoArg(cls, offSel, NO, (IMP)hookServerPropsDisableExperimental, &orig_serverPropsDisableExperimental);
            }
            if (gServerPropsDisableExperimentalHooked) break;
        }
    }

    Class debugVC = NSClassFromString(@"WADebugViewController");
    if (!gDebugCreateSectionsHooked) {
        SEL createSel = NSSelectorFromString(@"createSections");
        Method m = debugVC ? class_getInstanceMethod(debugVC, createSel) : NULL;
        if (m) {
            IMP orig = NULL;
            MSHookMessageEx(debugVC, createSel, (IMP)hookDebugCreateSections, &orig);
            if (orig) {
                orig_debugCreateSections = (void (*)(id, SEL))orig;
                gDebugCreateSectionsHooked = YES;
            }
        }
    }

    if (debugVC && !gDebugTableRowsHooked) {
        SEL sel = NSSelectorFromString(@"tableView:numberOfRowsInSection:");
        Method m = class_getInstanceMethod(debugVC, sel);
        if (m) {
            IMP orig = NULL;
            MSHookMessageEx(debugVC, sel, (IMP)hookDebugRows, &orig);
            if (orig) { orig_debugRows = (WAGRRowsIMP)orig; gDebugTableRowsHooked = YES; }
        }
    }

    if (debugVC && !gDebugTableCellHooked) {
        SEL sel = NSSelectorFromString(@"tableView:cellForRowAtIndexPath:");
        Method m = class_getInstanceMethod(debugVC, sel);
        if (m) {
            IMP orig = NULL;
            MSHookMessageEx(debugVC, sel, (IMP)hookDebugCell, &orig);
            if (orig) { orig_debugCell = (WAGRCellIMP)orig; gDebugTableCellHooked = YES; }
        }
    }

    if (debugVC && !gDebugTableSelectHooked) {
        SEL sel = NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:");
        Method m = class_getInstanceMethod(debugVC, sel);
        if (m) {
            IMP orig = NULL;
            MSHookMessageEx(debugVC, sel, (IMP)hookDebugSelect, &orig);
            if (orig) { orig_debugSelect = (WAGRSelectIMP)orig; gDebugTableSelectHooked = YES; }
        }
    }

    NSLog(@"[WATweaks][NativeDevMenu] install pass: allowed=%@ shortcut=%@ disableExperimental=%@ debugTable=%@",
          gDevMenuHooked ? @"YES" : @"NO",
          gShortcutHooked ? @"YES" : @"NO",
          gServerPropsDisableExperimentalHooked ? @"YES" : @"NO",
          (gDebugTableRowsHooked && gDebugTableCellHooked && gDebugTableSelectHooked) ? @"YES" : @"NO");
}

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) {
    installNativeDevMenuHooks();
}

extern "C" NSString *WAGRNativeDevMenuDiagnosticText(void) {
    Class swiftCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    Class debugVC = NSClassFromString(@"WADebugViewController");
    Class privateExp = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
    return [NSString stringWithFormat:
            @"DebugMenuProvider=%@\nWADebugViewController=%@\nPrivateExperimentationVC=%@\nallowedHook=%@\nshortcutHook=%@\ndisableExperimentalHook=%@\ndebugCreateSectionsHook=%@\ndebugTableRows=%@\ndebugTableCell=%@\ndebugTableSelect=%@\nmcDebugUI=%@\nprivateABDevOnly=%@\nprivateExpSync=%@\ndogfoodNudge=%@\nserverPropsDisableExperimental=%@",
            swiftCls ? @"loaded" : @"missing",
            debugVC ? @"loaded" : @"missing",
            privateExp ? @"loaded" : @"missing",
            gDevMenuHooked ? @"YES" : @"NO",
            gShortcutHooked ? @"YES" : @"NO",
            gServerPropsDisableExperimentalHooked ? @"YES" : @"NO",
            gDebugCreateSectionsHooked ? @"YES" : @"NO",
            gDebugTableRowsHooked ? @"YES" : @"NO",
            gDebugTableCellHooked ? @"YES" : @"NO",
            gDebugTableSelectHooked ? @"YES" : @"NO",
            WAGRGateForcedOn(@"waios_mc_debug_ui_enabled") ? @"ON" : @"system",
            WAGRGateForcedOn(@"private_abprop_for_dev_only") ? @"ON" : @"system",
            WAGRGateForcedOn(@"private_experimentation_should_sync") ? @"ON" : @"system",
            WAGRGateForcedOn(@"dogfooding_nudge_settings_entrypoint_enabled") ? @"ON" : @"system",
            WAGRGateForcedOff(@"serverPropsDisableExperimental") ? @"OFF" : @"system"];
}

__attribute__((constructor))
static void WAGRNativeDevMenuCtor(void) {
    @autoreleasepool {
        installNativeDevMenuHooks();
    }
}
