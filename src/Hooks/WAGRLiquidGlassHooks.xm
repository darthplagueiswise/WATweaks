#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

#include <string.h>

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

static NSDictionary<NSString *, NSString *> *WAGRLGSemanticMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"hasLiquidGlassLaunched" : @"ios_liquid_glass_launched",
            @"isM0Enabled" : @"ios_liquid_glass_media_m0",
            @"isM1Enabled" : @"ios_liquid_glass_m1",
            @"isM1_5Enabled" : @"ios_liquid_glass_m_1_5",
            @"isNewChatbarUXEnabled" : @"ios_liquid_glass_enable_new_chatbar_ux",
            @"isChatTopBarM2Enabled" : @"ios_liquid_glass_chat_top_bar_m2_enabled",
            @"isTextLayoutM2Enabled" : @"ios_liquid_glass_text_layout_m2_enabled",
            @"isM1_5ContextMenuEnabled" : @"ios_liquid_glass_m_1_5_context_menu",
            @"isActionTileM2Enabled" : @"ios_liquid_glass_m_2_action_tile",
            @"isUnifyUIRefreshEnabled" : @"ios_liquid_glass_unify_ui_refresh_enabled",
            @"isUnifyNavigationBarEnabled" : @"ios_liquid_glass_unify_navigation_bar_enabled",
            @"isNativeSidebarEnabled" : @"ios_liquid_glass_native_sidebar_enabled",
        };
    });
    return map;
}

static NSSet<NSString *> *WAGRLGPrimaryPositiveSemanticSelectors(void) {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"isChatbarLowerBottomPaddingEnabled",
            @"shouldUseNativeSwipeActions",
            @"isTopBarAppearanceWorkaroundEnabled",
            @"isFixesForOlderOSEnabled",
            @"isFixTabbarBadgeOffthreadEnabled",
            @"isContextMenuTransitionSafetyFixEnabled",
            @"isFixContextMenuOnDisappearEnabled",
            @"isFixUpdatesTableDynamicColorEnabled",
        ]];
    });
    return set;
}

static NSSet<NSString *> *WAGRLGPrimaryNegativeSemanticSelectors(void) {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"isCustomToolbarDisabledForLiquidGlass",
            @"isHidingBottomBarWorkaroundEnabled",
        ]];
    });
    return set;
}

static BOOL WAGRLGGateOverride(NSString *selector, BOOL *outValue) {
    if (!selector.length || !WAGRGateIsSet(selector)) return NO;
    if (outValue) *outValue = WAGRGateGet(selector);
    return YES;
}

extern "C" BOOL WAGRLGEffectiveMasterEnabled(void) {
    BOOL value = NO;
    return WAGRLGGateOverride(@"ios_liquid_glass_enabled", &value) && value;
}

static BOOL WAGRLGSemanticOverride(SEL selector, BOOL *outValue) {
    NSString *semantic = NSStringFromSelector(selector) ?: @"";
    NSString *abSelector = WAGRLGSemanticMap()[semantic];
    BOOL value = NO;
    if (abSelector.length && WAGRLGGateOverride(abSelector, &value)) {
        if (outValue) *outValue = value;
        return YES;
    }

    BOOL primary = NO;
    if (!WAGRLGGateOverride(@"ios_liquid_glass_enabled", &primary)) return NO;
    if ([WAGRLGPrimaryPositiveSemanticSelectors() containsObject:semantic]) {
        if (outValue) *outValue = primary;
        return YES;
    }
    if ([WAGRLGPrimaryNegativeSemanticSelectors() containsObject:semantic]) {
        if (outValue) *outValue = !primary;
        return YES;
    }
    return NO;
}

static BOOL WAGRLGHookedBool(id self, SEL _cmd) {
    BOOL forced = NO;
    if (WAGRLGSemanticOverride(_cmd, &forced)) return forced;
    NSValue *origValue = gWAGRLGOrigIMPs[NSStringFromSelector(_cmd) ?: @""];
    IMP imp = origValue ? reinterpret_cast<IMP>([origValue pointerValue]) : NULL;
    return imp ? ((BOOL (*)(id, SEL))imp)(self, _cmd) : NO;
}

static void WAGRLGApplyLegacyDefaults(void) {
    // Optional compatibility bridge only. It never owns Liquid Glass feature state.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = WAGRLGEffectiveMasterEnabled() && WAGRPref(WA_PREF_LIQUID_GLASS_USERDEFAULTS);
    for (NSString *key in @[@"liquid_glass_override_enabled", @"WALiquidGlassOverrideEnabled"]) {
        if (enabled) [defaults setBool:YES forKey:key];
        else [defaults removeObjectForKey:key];
    }
    [defaults synchronize];

    Class cls = NSClassFromString(@"WALiquidGlassOverrideMethodUserDefaults");
    if (!cls) return;
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    Method sharedMethod = class_getClassMethod(cls, sharedSelector);
    if (!sharedMethod || method_getNumberOfArguments(sharedMethod) != 2) return;
    id instance = nil;
    @try { instance = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSelector); }
    @catch (__unused NSException *exception) { instance = nil; }
    if (!instance) return;
    SEL setSelector = NSSelectorFromString(@"setEnabled:");
    if (![instance respondsToSelector:setSelector]) return;
    NSMethodSignature *signature = [instance methodSignatureForSelector:setSelector];
    if (!signature || signature.numberOfArguments != 3) return;
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
        if (original) gWAGRLGOrigIMPs[name] = [NSValue valueWithPointer:reinterpret_cast<const void *>(original)];
    }
}

static BOOL WAGRLGHasAnyCanonicalOverride(void) {
    for (NSString *selector in WAGRLGManagedWAABKeys()) if (WAGRGateIsSet(selector)) return YES;
    return NO;
}

extern "C" void WAGRLGPrefsDidChange(void) {
    WAGRLGApplyLegacyDefaults();
    if (WAGRLGHasAnyCanonicalOverride() || WAGRPref(WA_PREF_LIQUID_GLASS_METHOD_HOOKS)) WAGRLGHookClass();
}

extern "C" void WAGRLGSetMasterEnabled(BOOL enabled) {
    // Compatibility API: mutate the same canonical ABProps as the submenu/browser.
    for (NSString *selector in WAGRLGManagedWAABKeys()) {
        if (enabled) WAGRGateSet(selector, YES);
        else WAGRGateClear(selector);
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kWAGRLiquidGlassMaster];
    [NSUserDefaults.standardUserDefaults synchronize];
    WAGRLGPrefsDidChange();
}

extern "C" NSString *WAGRLGDiagnosticText(void) {
    NSMutableArray *active = [NSMutableArray array];
    for (NSString *selector in WAGRLGManagedWAABKeys()) {
        if (WAGRGateIsSet(selector)) [active addObject:[NSString stringWithFormat:@"%@=%@", selector, WAGRGateGet(selector) ? @"YES" : @"NO"]];
    }
    return [NSString stringWithFormat:
        @"parallelMaster=NO\ncanonicalState=GateStore/RuntimeValueStore\nprimary=%@\nactive=%@\nmethodHooks=%@\nNSUserDefaultsBridge=%@\nWDS=%@\nhookAttempted=%@\nhookedWDS=%lu/%lu",
        WAGRLGEffectiveMasterEnabled() ? @"ON" : @"OFF",
        active.count ? [active componentsJoinedByString:@", "] : @"none",
        WAGRPref(WA_PREF_LIQUID_GLASS_METHOD_HOOKS) ? @"ON" : @"OFF",
        WAGRPref(WA_PREF_LIQUID_GLASS_USERDEFAULTS) ? @"ON" : @"OFF",
        NSClassFromString(@"WDSLiquidGlass") ? @"found" : @"missing",
        gWAGRLGHookInstallAttempted ? @"YES" : @"NO",
        (unsigned long)gWAGRLGOrigIMPs.count,
        (unsigned long)WAGRLGWDSSelectors().count];
}

__attribute__((constructor))
static void WAGRLGConstructor(void) {
    @autoreleasepool {
        // Remove obsolete master preference from older builds; exact WAAB overrides
        // survive independently in RuntimeValueStore.
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWAGRLiquidGlassMaster];
        if (WAGRLGHasAnyCanonicalOverride() ||
            WAGRPref(WA_PREF_LIQUID_GLASS_METHOD_HOOKS) ||
            WAGRPref(WA_PREF_LIQUID_GLASS_USERDEFAULTS)) {
            WAGRLGPrefsDidChange();
        }
    }
}
