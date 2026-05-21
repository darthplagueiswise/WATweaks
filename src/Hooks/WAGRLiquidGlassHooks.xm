#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

static BOOL gWAGRLGHookInstallAttempted = NO;

static void WAGRLGApplyNative(void){
    NSUserDefaults*ud=NSUserDefaults.standardUserDefaults;
    BOOL on=WAGRPref(kWAGRLiquidGlassMaster);
    NSArray*keys=@[@"liquid_glass_override_enabled",@"WALiquidGlassOverrideEnabled",
        @"wa_lg_ios_liquid_glass_enabled",@"wa_lg_ios_liquid_glass_launched",@"wa_lg_ios_liquid_glass_m1",
        @"wa_lg_ios_liquid_glass_m_1_5",@"wa_lg_ios_liquid_glass_m_1_5_context_menu",
        @"wa_lg_ios_liquid_glass_chat_top_bar_m2_enabled",@"wa_lg_ios_liquid_glass_enable_new_chatbar_ux",
        @"wa_lg_ios_liquid_glass_larger_composer",@"wa_lg_ios_liquid_glass_reduce_transparency",
        @"wa_lg_ios_liquid_glass_workaround_attachment_tray",@"wa_lg_ios_liquid_glass_workaround_hides_bottombar",
        @"wa_lg_ios_liquid_glass_workaround_topbar_appearance",
        @"ios_liquid_glass_enabled",@"ios_liquid_glass_launched",@"ios_liquid_glass_m1",
        @"ios_liquid_glass_m_1_5",@"ios_liquid_glass_m_1_5_context_menu",@"ios_liquid_glass_media_m0",
        @"ios_liquid_glass_larger_composer",@"ios_liquid_glass_media_editor_enabled",
        @"ios_liquid_glass_calling_improvement_enabled",@"ios_liquid_glass_workaround_attachment_tray",
        @"status_viewer_redesign_enabled"];
    for(NSString*k in keys){if(on)[ud setBool:YES forKey:k];else[ud removeObjectForKey:k];}
    [ud synchronize];

    // Native override bridge is only touched when the master is ON. When OFF,
    // clearing NSUserDefaults is enough and avoids instantiating WhatsApp internals at launch.
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

// MSHookMessageEx for WDSLiquidGlass — no Logos.
// Uses one generic class-method trampoline keyed by selector so the master
// LiquidGlass pref can cover every WDSLiquidGlass BOOL getter FLEX exposed.
typedef BOOL (*ClassBoolIMP)(id,SEL);
static NSMutableDictionary<NSString *, NSValue *> *gWAGRLGOriginals = nil;
static NSMutableSet<NSString *> *gWAGRLGInvertedSelectors = nil;

static BOOL hWAGRLGGeneric(id self, SEL _cmd) {
    NSString *selName = NSStringFromSelector(_cmd);
    BOOL inverted = [gWAGRLGInvertedSelectors containsObject:selName];
    if (WAGRPref(kWAGRLiquidGlassMaster)) return inverted ? NO : YES;

    ClassBoolIMP orig = NULL;
    NSValue *v = gWAGRLGOriginals[selName];
    if (v) orig = reinterpret_cast<ClassBoolIMP>([v pointerValue]);
    return orig ? orig(self, _cmd) : NO;
}

static void WAGRLGHookClass(void){
    if(!WAGRPref(kWAGRLiquidGlassMaster))return;
    Class cls=NSClassFromString(@"WDSLiquidGlass");if(!cls)return;
    Class meta=object_getClass(cls);
    if(!gWAGRLGOriginals) gWAGRLGOriginals=[NSMutableDictionary dictionary];
    if(!gWAGRLGInvertedSelectors) gWAGRLGInvertedSelectors=[NSMutableSet set];

    NSArray<NSString *> *selectors=@[
        @"hasLiquidGlassLaunched",
        @"isM0Enabled",
        @"isM1Enabled",
        @"isM1_5Enabled",
        @"isNewChatbarUXEnabled",
        @"isChatbarLowerBottomPaddingEnabled",
        @"isChatTopBarM2Enabled",
        @"isTextLayoutM2Enabled",
        @"isM1_5ContextMenuEnabled",
        @"isActionTileM2Enabled",
        @"isUnifyUIRefreshEnabled",
        @"isUnifyNavigationBarEnabled",
        @"shouldUseNativeSwipeActions",
        @"isHidingBottomBarWorkaroundEnabled",
        @"isTopBarAppearanceWorkaroundEnabled",
        @"isFixesForOlderOSEnabled",
        @"isFixTabbarBadgeOffthreadEnabled",
        @"isContextMenuTransitionSafetyFixEnabled",
        @"isFixContextMenuOnDisappearEnabled",
        @"isFixUpdatesTableDynamicColorEnabled",
        @"isNativeSidebarEnabled",
        @"isCustomToolbarDisabledForLiquidGlass"
    ];
    [gWAGRLGInvertedSelectors addObject:@"isCustomToolbarDisabledForLiquidGlass"];

    for(NSString *name in selectors){
        if(gWAGRLGOriginals[name])continue;
        SEL sel=NSSelectorFromString(name);
        Method m=class_getClassMethod(cls,sel);if(!m)continue;
        if(method_getNumberOfArguments(m)!=2)continue;
        char ret[8]={0}; method_getReturnType(m, ret, sizeof(ret));
        if(ret[0]!='B' && ret[0]!='c')continue;
        IMP orig=NULL;
        MSHookMessageEx(meta,sel,(IMP)hWAGRLGGeneric,&orig);
        if(orig)gWAGRLGOriginals[name]=[NSValue valueWithPointer:(const void *)orig];
    }
}

static void WAGRLGInstallOnlyIfEnabled(void){
    if(!WAGRPref(kWAGRLiquidGlassMaster))return;
    WAGRLGApplyNative();
    if(!gWAGRLGHookInstallAttempted){
        gWAGRLGHookInstallAttempted=YES;
        WAGRLGHookClass();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{WAGRLGHookClass();});
    }
}

// IMPORTANT: no constructor here. Startup must be inert. This is called only
// from the menu/toggle path, after the user explicitly enables LiquidGlass.
extern "C" void WAGRLGPrefsDidChange(void){WAGRLGInstallOnlyIfEnabled(); if(!WAGRPref(kWAGRLiquidGlassMaster))WAGRLGApplyNative();}
extern "C" NSString *WAGRLGDiagnosticText(void){
    return [NSString stringWithFormat:@"master=%@\nWDS=%@\nWAAB=%@\nhookAttempted=%@",
        WAGRPref(kWAGRLiquidGlassMaster)?@"ON":@"OFF",
        NSClassFromString(@"WDSLiquidGlass")?@"found":@"missing",
        NSClassFromString(@"WAABProperties")?@"found":@"missing",
        gWAGRLGHookInstallAttempted?@"YES":@"NO"];
}