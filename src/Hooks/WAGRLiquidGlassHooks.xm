#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

static BOOL gWAGRLGHookInstallAttempted = NO;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRLGOrigIMPs = nil;

static NSArray<NSString *> *WAGRLGManagedWAABKeys(void) {
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"ios_liquid_glass_enabled",
            @"ios_liquid_glass_launched",
            @"ios_liquid_glass_m1",
            @"ios_liquid_glass_m_1_5",
            @"ios_liquid_glass_m_1_5_context_menu",
            @"ios_liquid_glass_media_m0",
            @"ios_liquid_glass_larger_composer",
            @"ios_liquid_glass_media_editor_enabled",
            @"ios_liquid_glass_calling_improvement_enabled",
            @"ios_liquid_glass_workaround_attachment_tray",
            @"ios_liquid_glass_enable_new_chatbar_ux",
            @"ios_liquid_glass_chat_top_bar_m2_enabled",
            @"ios_liquid_glass_text_layout_m2_enabled",
            @"ios_liquid_glass_m_2_action_tile",
            @"ios_liquid_glass_unify_ui_refresh_enabled",
            @"ios_liquid_glass_unify_navigation_bar_enabled",
            @"ios_liquid_glass_native_sidebar_enabled",
            @"status_viewer_redesign_enabled",
        ];
    });
    return keys;
}

static NSDictionary *WAGRLGManagedGateBackup(void) {
    id value = [NSUserDefaults.standardUserDefaults
        objectForKey:WA_PREF_LIQUID_GLASS_MANAGED_GATE_BACKUP];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static void WAGRLGBackupAndEnableManagedWAAB(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *backup = [WAGRLGManagedGateBackup() mutableCopy];
    if (!backup) backup = [NSMutableDictionary dictionary];

    for (NSString *key in WAGRLGManagedWAABKeys()) {
        if (!backup[key]) {
            BOOL present = WAGRGateIsSet(key);
            backup[key] = @{
                @"present" : @(present),
                @"value" : @(present ? WAGRGateGet(key) : NO),
            };
        }
        WAGRGateSet(key, YES);
    }
    [defaults setObject:backup forKey:WA_PREF_LIQUID_GLASS_MANAGED_GATE_BACKUP];
    [defaults synchronize];
}

static void WAGRLGRestoreManagedWAAB(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *backup = WAGRLGManagedGateBackup();
    for (NSString *key in WAGRLGManagedWAABKeys()) {
        NSDictionary *entry = [backup[key] isKindOfClass:NSDictionary.class] ? backup[key] : nil;
        if (entry && [entry[@"present"] boolValue]) {
            WAGRGateSet(key, [entry[@"value"] boolValue]);
        } else {
            WAGRGateClear(key);
        }
    }
    [defaults removeObjectForKey:WA_PREF_LIQUID_GLASS_MANAGED_GATE_BACKUP];
    [defaults synchronize];
}

extern "C" BOOL WAGRLGEffectiveMasterEnabled(void) {
    if (WAGRRuntimeValueHasOverride(@"WAABProperties", @"ios_liquid_glass_enabled", NO)) {
        id value = WAGRRuntimeValueOverride(@"WAABProperties", @"ios_liquid_glass_enabled", NO);
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    }
    if (WAGRGateIsSet(@"ios_liquid_glass_enabled")) {
        return WAGRGateGet(@"ios_liquid_glass_enabled");
    }
    return WAGRPref(kWAGRLiquidGlassMaster);
}

static BOOL WAGRLGSelectorIsNegative(SEL sel) {
    NSString *s = NSStringFromSelector(sel).lowercaseString ?: @"";
    return [s containsString:@"disabled"];
}

static BOOL WAGRLGHookedBool(id self, SEL _cmd) {
    if (WAGRLGEffectiveMasterEnabled()) return !WAGRLGSelectorIsNegative(_cmd);
    NSValue *origValue = gWAGRLGOrigIMPs[NSStringFromSelector(_cmd)];
    IMP imp = origValue ? reinterpret_cast<IMP>([origValue pointerValue]) : NULL;
    if (imp) return ((BOOL (*)(id, SEL))imp)(self, _cmd);
    return NO;
}

static void WAGRLGApplyLegacyDefaults(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = WAGRLGEffectiveMasterEnabled() && WAGRPref(WA_PREF_LIQUID_GLASS_USERDEFAULTS);
    NSArray *keys = @[
        @"liquid_glass_override_enabled",
        @"WALiquidGlassOverrideEnabled",
    ];
    for (NSString *key in keys) {
        if (enabled) [defaults setBool:YES forKey:key];
        else [defaults removeObjectForKey:key];
    }
    [defaults synchronize];

    Class cls = NSClassFromString(@"WALiquidGlassOverrideMethodUserDefaults");
    if (!cls) return;
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if (!class_respondsToSelector(object_getClass(cls), sharedSelector)) return;
    id instance = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSelector);
    if (!instance) return;
    SEL setSelector = NSSelectorFromString(@"setEnabled:");
    if (![instance respondsToSelector:setSelector]) return;
    NSMethodSignature *signature = [instance methodSignatureForSelector:setSelector];
    if (!signature) return;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:setSelector];
    [invocation setTarget:instance];
    BOOL value = enabled;
    [invocation setArgument:&value atIndex:2];
    [invocation invoke];
}

static NSArray<NSString *> *WAGRLGWDSSelectors(void) {
    return @[@"hasLiquidGlassLaunched", @"isM0Enabled", @"isM1Enabled", @"isM1_5Enabled",
             @"isNewChatbarUXEnabled", @"isChatbarLowerBottomPaddingEnabled", @"isChatTopBarM2Enabled",
             @"isTextLayoutM2Enabled", @"isM1_5ContextMenuEnabled", @"isActionTileM2Enabled",
             @"isUnifyUIRefreshEnabled", @"isCustomToolbarDisabledForLiquidGlass",
             @"isUnifyNavigationBarEnabled", @"shouldUseNativeSwipeActions", @"isHidingBottomBarWorkaroundEnabled",
             @"isTopBarAppearanceWorkaroundEnabled", @"isFixesForOlderOSEnabled",
             @"isFixTabbarBadgeOffthreadEnabled", @"isContextMenuTransitionSafetyFixEnabled",
             @"isFixContextMenuOnDisappearEnabled", @"isFixUpdatesTableDynamicColorEnabled",
             @"isNativeSidebarEnabled"];
}

static void WAGRLGHookClass(void) {
    Class cls = NSClassFromString(@"WDSLiquidGlass");
    if (!cls) return;
    Class meta = object_getClass(cls);
    if (!meta) return;
    if (!gWAGRLGOrigIMPs) gWAGRLGOrigIMPs = [NSMutableDictionary dictionary];
    gWAGRLGHookInstallAttempted = YES;
    for (NSString *name in WAGRLGWDSSelectors()) {
        if (gWAGRLGOrigIMPs[name]) continue;
        SEL sel = NSSelectorFromString(name);
        Method method = class_getClassMethod(cls, sel);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char rawReturn[16] = {0};
        method_getReturnType(method, rawReturn, sizeof(rawReturn));
        if (rawReturn[0] != 'B' && rawReturn[0] != 'c') continue;
        IMP original = NULL;
        MSHookMessageEx(meta, sel, (IMP)WAGRLGHookedBool, &original);
        if (original) {
            gWAGRLGOrigIMPs[name] = [NSValue valueWithPointer:reinterpret_cast<const void *>(original)];
        }
    }
}

static void WAGRLGInstallOnlyIfEnabled(void) {
    if (!WAGRLGEffectiveMasterEnabled()) return;
    if (!WAGRPref(WA_PREF_LIQUID_GLASS_METHOD_HOOKS)) return;
    WAGRLGHookClass();
}

extern "C" void WAGRLGPrefsDidChange(void) {
    WAGRLGApplyLegacyDefaults();
    WAGRLGInstallOnlyIfEnabled();
}

extern "C" void WAGRLGSetMasterEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kWAGRLiquidGlassMaster];
    if (enabled) WAGRLGBackupAndEnableManagedWAAB();
    else WAGRLGRestoreManagedWAAB();
    [NSUserDefaults.standardUserDefaults synchronize];
    WAGRLGPrefsDidChange();
}

extern "C" NSString *WAGRLGDiagnosticText(void) {
    BOOL runtimeOverride = WAGRRuntimeValueHasOverride(@"WAABProperties",
                                                       @"ios_liquid_glass_enabled", NO);
    return [NSString stringWithFormat:
        @"localMaster=%@\neffectiveMaster=%@\nWAAB ios_liquid_glass_enabled override=%@\nmethodHooks=%@\nNSUserDefaults bridge=%@\nWDS=%@\nWAAB=%@\nhookAttempted=%@\nhookedWDS=%lu/%lu\nmanagedBackup=%lu",
        WAGRPref(kWAGRLiquidGlassMaster) ? @"ON" : @"OFF",
        WAGRLGEffectiveMasterEnabled() ? @"ON" : @"OFF",
        runtimeOverride ? @"YES" : @"NO",
        WAGRPref(WA_PREF_LIQUID_GLASS_METHOD_HOOKS) ? @"ON" : @"OFF",
        WAGRPref(WA_PREF_LIQUID_GLASS_USERDEFAULTS) ? @"ON" : @"OFF",
        NSClassFromString(@"WDSLiquidGlass") ? @"found" : @"missing",
        NSClassFromString(@"WAABProperties") ? @"found" : @"missing",
        gWAGRLGHookInstallAttempted ? @"YES" : @"NO",
        (unsigned long)gWAGRLGOrigIMPs.count,
        (unsigned long)WAGRLGWDSSelectors().count,
        (unsigned long)WAGRLGManagedGateBackup().count];
}

__attribute__((constructor))
static void WAGRLGConstructor(void) {
    @autoreleasepool {
        // RuntimeValueStore owns persisted WAAB overrides. Do not rewrite them at
        // launch. Only rebuild optional semantic WDS/default bridges if requested.
        if (WAGRPref(WA_PREF_LIQUID_GLASS_METHOD_HOOKS) ||
            WAGRPref(WA_PREF_LIQUID_GLASS_USERDEFAULTS)) {
            WAGRLGPrefsDidChange();
        }
    }
}