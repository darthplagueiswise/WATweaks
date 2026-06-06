#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import "../WAGramPrefix.h"

static BOOL gWAGRLGHookInstallAttempted = NO;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRLGOrigIMPs = nil;

static BOOL WAGRLGSelectorIsNegative(SEL sel) {
    NSString *s = NSStringFromSelector(sel).lowercaseString ?: @"";
    return [s containsString:@"disabled"];
}

static BOOL WAGRLGHookedBool(id self, SEL _cmd) {
    if (WAGRPref(kWAGRLiquidGlassMaster)) return !WAGRLGSelectorIsNegative(_cmd);
    NSValue *origValue = gWAGRLGOrigIMPs[NSStringFromSelector(_cmd)];
    IMP imp = origValue ? reinterpret_cast<IMP>([origValue pointerValue]) : NULL;
    if (imp) return ((BOOL (*)(id, SEL))imp)(self, _cmd);
    return NO;
}

static void WAGRLGApplyNative(void){
    NSUserDefaults*ud=NSUserDefaults.standardUserDefaults;
    BOOL on=WAGRPref(kWAGRLiquidGlassMaster);
    NSArray*keys=@[@"liquid_glass_override_enabled",@"WALiquidGlassOverrideEnabled",
        @"ios_liquid_glass_enabled",@"ios_liquid_glass_launched",@"ios_liquid_glass_m1",
        @"ios_liquid_glass_m_1_5",@"ios_liquid_glass_m_1_5_context_menu",@"ios_liquid_glass_media_m0",
        @"ios_liquid_glass_larger_composer",@"ios_liquid_glass_media_editor_enabled",
        @"ios_liquid_glass_calling_improvement_enabled",@"ios_liquid_glass_workaround_attachment_tray",
        @"ios_liquid_glass_enable_new_chatbar_ux",@"ios_liquid_glass_chat_top_bar_m2_enabled",
        @"ios_liquid_glass_text_layout_m2_enabled",@"ios_liquid_glass_m_2_action_tile",
        @"ios_liquid_glass_unify_ui_refresh_enabled",@"ios_liquid_glass_unify_navigation_bar_enabled",
        @"ios_liquid_glass_native_sidebar_enabled",@"status_viewer_redesign_enabled"];
    for(NSString*k in keys){if(on)[ud setBool:YES forKey:k];else[ud removeObjectForKey:k];}
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
             @"isUnifyUIRefreshEnabled", @"isCustomToolbarDisabledForLiquidGlass",
             @"isUnifyNavigationBarEnabled", @"shouldUseNativeSwipeActions", @"isHidingBottomBarWorkaroundEnabled",
             @"isTopBarAppearanceWorkaroundEnabled", @"isFixesForOlderOSEnabled",
             @"isFixTabbarBadgeOffthreadEnabled", @"isContextMenuTransitionSafetyFixEnabled",
             @"isFixContextMenuOnDisappearEnabled", @"isFixUpdatesTableDynamicColorEnabled",
             @"isNativeSidebarEnabled"];
}

static NSUInteger WAGRLGHookClass(void){
    if(!WAGRPref(kWAGRLiquidGlassMaster))return 0;
    Class cls=NSClassFromString(@"WDSLiquidGlass");if(!cls)return 0;
    Class meta=object_getClass(cls);if(!meta)return 0;
    if(!gWAGRLGOrigIMPs)gWAGRLGOrigIMPs=[NSMutableDictionary dictionary];
    NSUInteger installed=0;
    for(NSString *name in WAGRLGWDSSelectors()){
        if(gWAGRLGOrigIMPs[name])continue;
        SEL sel=NSSelectorFromString(name);
        Method m=class_getClassMethod(cls,sel);if(!m)continue;
        IMP orig=NULL;
        MSHookMessageEx(meta,sel,(IMP)WAGRLGHookedBool,&orig);
        if(orig){
            gWAGRLGOrigIMPs[name]=[NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
            installed++;
            NSLog(@"[WATweaks][LiquidGlass] hooked WDSLiquidGlass +%@", name);
        }
    }
    if(gWAGRLGOrigIMPs.count>0)gWAGRLGHookInstallAttempted=YES;
    return installed;
}

static void WAGRLGInstallOnlyIfEnabled(void){
    if(!WAGRPref(kWAGRLiquidGlassMaster))return;
    WAGRLGApplyNative();
    // Always retry. WAGRLGHookClass is idempotent and gWAGRLGOrigIMPs prevents double-hooking.
    WAGRLGHookClass();
}

extern "C" void WAGRLGPrefsDidChange(void){WAGRLGInstallOnlyIfEnabled(); if(!WAGRPref(kWAGRLiquidGlassMaster))WAGRLGApplyNative();}
extern "C" NSString *WAGRLGDiagnosticText(void){
    return [NSString stringWithFormat:@"master=%@\nWDS=%@\nWAAB=%@\nhookAttempted=%@\nhookedWDS=%lu/22",
        WAGRPref(kWAGRLiquidGlassMaster)?@"ON":@"OFF",
        NSClassFromString(@"WDSLiquidGlass")?@"found":@"missing",
        NSClassFromString(@"WAABProperties")?@"found":@"missing",
        gWAGRLGHookInstallAttempted?@"YES":@"NO",
        (unsigned long)gWAGRLGOrigIMPs.count];
}

static void WAGRLGDyldCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh; (void)vmaddr_slide;
    dispatch_async(dispatch_get_main_queue(), ^{ WAGRLGPrefsDidChange(); });
}

__attribute__((constructor))
static void WAGRLGConstructor(void) {
    @autoreleasepool {
        WAGRLGPrefsDidChange();
        _dyld_register_func_for_add_image(WAGRLGDyldCallback);
    }
}
