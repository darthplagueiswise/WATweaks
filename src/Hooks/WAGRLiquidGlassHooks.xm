#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"

static BOOL gWAGRLGHookInstallAttempted = NO;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRLGOrigIMPs = nil;

static BOOL WAGRLGSelectorIsNegative(SEL sel) {
    NSString *s = NSStringFromSelector(sel).lowercaseString ?: @"";
    return [s containsString:@"disabled"] || [s containsString:@"customtoolbardisabled"] || [s containsString:@"reducetransparency"];
}

static BOOL WAGRLGHookedBool(id self, SEL _cmd) {
    if (WAGRPref(kWAGRLiquidGlassMaster)) return !WAGRLGSelectorIsNegative(_cmd);
    NSValue *origValue = gWAGRLGOrigIMPs[NSStringFromSelector(_cmd)];
    IMP imp = origValue ? reinterpret_cast<IMP>([origValue pointerValue]) : NULL;
    if (imp) return ((BOOL (*)(id, SEL))imp)(self, _cmd);
    return NO;
}

static NSArray<NSString *> *WAGRLGWAABKeys(void) {
    return @[
        @"ios_liquid_glass_enabled",
        @"ios_liquid_glass_launched",
        @"ios_liquid_glass_media_m0",
        @"ios_liquid_glass_m1",
        @"ios_liquid_glass_m_1_5",
        @"ios_liquid_glass_m_1_5_context_menu",
        @"ios_liquid_glass_chat_top_bar_m2_enabled",
        @"ios_liquid_glass_chatbar_lower_bottom_padding",
        @"ios_liquid_glass_enable_new_chatbar_ux",
        @"ios_liquid_glass_larger_composer",
        @"ios_liquid_glass_m_2_action_tile",
        @"ios_liquid_glass_m_2_chips",
        @"ios_liquid_glass_m_2_lightweight_dialogs",
        @"ios_liquid_glass_m_2_text_layout",
        @"ios_liquid_glass_media_editor_enabled",
        @"ios_liquid_glass_calling_improvement_enabled",
        @"ios_liquid_glass_ptt_oot",
        @"ios_liquid_glass_fixes_for_older_ios",
        @"ios_liquid_glass_fix_context_menu_on_disappear",
        @"ios_liquid_glass_fix_context_menu_transition_safety",
        @"ios_liquid_glass_fix_feedback_generator_retain",
        @"ios_liquid_glass_fix_forward_picker_share_extension_crash",
        @"ios_liquid_glass_fix_me_tab_profile_render_throttle_enabled",
        @"ios_liquid_glass_fix_multisend_preview_dealloc",
        @"ios_liquid_glass_fix_status_dismiss_when_locked",
        @"ios_liquid_glass_fix_tabbar_badge_offthread",
        @"ios_liquid_glass_fix_uiimage_trait_collection",
        @"ios_liquid_glass_fix_updates_table_dynamic_color",
        @"ios_liquid_glass_fix_voip_mutex_priority_inversion",
        @"ios_liquid_glass_fix_weak_hashtable_snapshot",
        @"ios_liquid_glass_unify_ui_refresh_enabled",
        @"ios_liquid_glass_unify_navigation_bar_enabled",
        @"ios_liquid_glass_native_sidebar_enabled",
        @"status_viewer_redesign_enabled"
    ];
}

static void WAGRLGApplyNative(void){
    NSUserDefaults*ud=NSUserDefaults.standardUserDefaults;
    BOOL on=WAGRPref(kWAGRLiquidGlassMaster);
    for(NSString*k in WAGRLGWAABKeys()){
        if(on){ [ud setBool:YES forKey:k]; WAGRGateSet(k, YES); }
        else { [ud removeObjectForKey:k]; WAGRGateClear(k); }
    }
    for (NSString *k in @[@"liquid_glass_override_enabled", @"WALiquidGlassOverrideEnabled"]) {
        if(on)[ud setBool:YES forKey:k]; else[ud removeObjectForKey:k];
    }
    [ud synchronize];
    if(!on)return;

    Class cls=NSClassFromString(@"WALiquidGlassOverrideMethodUserDefaults");
    if(!cls)return;
    SEL sh=NSSelectorFromString(@"sharedInstance");
    if(!class_respondsToSelector(object_getClass(cls),sh))return;
    id inst=((id(*)(id,SEL))objc_msgSend)((id)cls,sh);
    if(!inst)return;
    SEL se=NSSelectorFromString(@"setEnabled:");
    if(![inst respondsToSelector:se])return;
    NSMethodSignature*sig=[inst methodSignatureForSelector:se];
    if(!sig)return;
    NSInvocation*inv=[NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:se];[inv setTarget:inst];BOOL y=on;[inv setArgument:&y atIndex:2];[inv invoke];
}

static NSArray<NSString *> *WAGRLGWDSSelectors(void) {
    return @[@"hasLiquidGlassLaunched", @"isM0Enabled", @"isM1Enabled", @"isM1_5Enabled",
             @"isNewChatbarUXEnabled", @"isChatbarLowerBottomPaddingEnabled", @"isChatTopBarM2Enabled",
             @"isTextLayoutM2Enabled", @"isM1_5ContextMenuEnabled", @"isActionTileM2Enabled",
             @"isUnifyUIRefreshEnabled", @"isUnifyHoverActionsEnabled", @"isCustomToolbarDisabledForLiquidGlass",
             @"isUnifyNavigationBarEnabled", @"shouldUseNativeSwipeActions", @"isHidingBottomBarWorkaroundEnabled",
             @"isTopBarAppearanceWorkaroundEnabled", @"isFixesForOlderOSEnabled",
             @"isFixTabbarBadgeOffthreadEnabled", @"isContextMenuTransitionSafetyFixEnabled",
             @"isFixContextMenuOnDisappearEnabled", @"isFixUpdatesTableDynamicColorEnabled",
             @"isNativeSidebarEnabled"];
}

static void WAGRLGHookClass(void){
    Class cls=NSClassFromString(@"WDSLiquidGlass");if(!cls)return;
    Class meta=object_getClass(cls);if(!meta)return;
    if(!gWAGRLGOrigIMPs)gWAGRLGOrigIMPs=[NSMutableDictionary dictionary];
    gWAGRLGHookInstallAttempted=YES;
    for(NSString *name in WAGRLGWDSSelectors()){
        if(gWAGRLGOrigIMPs[name])continue;
        SEL sel=NSSelectorFromString(name);
        Method m=class_getClassMethod(cls,sel);if(!m)continue;
        IMP orig=NULL;
        MSHookMessageEx(meta,sel,(IMP)WAGRLGHookedBool,&orig);
        if(orig)gWAGRLGOrigIMPs[name]=[NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    }
}

static void WAGRLGInstallOnlyIfEnabled(void){
    WAGRLGHookClass();
    WAGRLGApplyNative();
}

extern "C" void WAGRLGPrefsDidChange(void){ WAGRLGInstallOnlyIfEnabled(); }
extern "C" NSString *WAGRLGDiagnosticText(void){
    return [NSString stringWithFormat:@"master=%@\nWDS=%@\nFOAWAAB=%@\nhookAttempted=%@\nhookedWDS=%lu/%lu\nwaabKeys=%lu",
        WAGRPref(kWAGRLiquidGlassMaster)?@"ON":@"OFF",
        NSClassFromString(@"WDSLiquidGlass")?@"found":@"missing",
        NSClassFromString(@"FOAWAABPropertiesImpl")?@"found":@"missing",
        gWAGRLGHookInstallAttempted?@"YES":@"NO",
        (unsigned long)gWAGRLGOrigIMPs.count,
        (unsigned long)WAGRLGWDSSelectors().count,
        (unsigned long)WAGRLGWAABKeys().count];
}

__attribute__((constructor))
static void WAGRLGConstructor(void){
    @autoreleasepool {
        WAGRLGHookClass();
        WAGRLGApplyNative();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRLGHookClass(); WAGRLGApplyNative(); });
    }
}
