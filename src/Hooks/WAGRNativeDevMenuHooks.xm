#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

typedef BOOL (*WAGRBoolIMP)(id, SEL);
static WAGRBoolIMP gOrigAllowed = NULL;
static WAGRBoolIMP gOrigShortcut = NULL;
static BOOL gAllowedHooked = NO;
static BOOL gShortcutHooked = NO;

static BOOL WAGRNativeDevAllowed(void) {
    return WAGRPref(kWAGRDebugMenuNative) || WAGRPref(kWAGRInternalMaster) || WAGRPref(kWAGREmployeeMaster) || WAGRPref(kWAGRDebugMode);
}

static BOOL hookAllowed(id self, SEL _cmd) { if (WAGRNativeDevAllowed()) return YES; return gOrigAllowed ? gOrigAllowed(self, _cmd) : NO; }
static BOOL hookShortcut(id self, SEL _cmd) { if (WAGRNativeDevAllowed()) return YES; return gOrigShortcut ? gOrigShortcut(self, _cmd) : NO; }

static BOOL WAGRClassHasMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int n=0; Method *ms=class_copyMethodList(cls,&n); BOOL ok=NO;
    for (unsigned int i=0;i<n;i++) if (method_getName(ms[i])==sel) { ok=YES; break; }
    if (ms) free(ms);
    return ok;
}

static void WAGRInstallNativeDevMenuHooks(void) {
    NSArray *candidates=@[@"_TtC15WADebugMenuMain17DebugMenuProvider", @"WASettingsViewController", @"WASettingsTableViewController", @"WANewSettingsViewController"];
    SEL allowed=NSSelectorFromString(@"isDebugMenuAllowed");
    SEL shortcut=NSSelectorFromString(@"isDebugMenuShortcutEnabled");
    for (NSString *name in candidates) {
        Class cls=NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (!cls) continue;
        if (!gAllowedHooked && WAGRClassHasMethod(cls, allowed)) { MSHookMessageEx(cls, allowed, (IMP)hookAllowed, (IMP *)&gOrigAllowed); gAllowedHooked=(gOrigAllowed!=NULL); }
        if (!gShortcutHooked && WAGRClassHasMethod(cls, shortcut)) { MSHookMessageEx(cls, shortcut, (IMP)hookShortcut, (IMP *)&gOrigShortcut); gShortcutHooked=(gOrigShortcut!=NULL); }
        if (gAllowedHooked && gShortcutHooked) break;
    }
}

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) { WAGRInstallNativeDevMenuHooks(); }
extern "C" NSString *WAGRNativeDevMenuDiagnosticText(void) {
    return [NSString stringWithFormat:@"swiftProvider=%@\nallowedHook=%@\nshortcutHook=%@\nmasterPref=%@",
            NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider") ? @"found" : @"missing",
            gAllowedHooked ? @"YES" : @"NO",
            gShortcutHooked ? @"YES" : @"NO",
            WAGRNativeDevAllowed() ? @"ON" : @"OFF"];
}

__attribute__((constructor)) static void WAGRNativeDevMenuCtor(void) {
    @autoreleasepool {
        WAGRInstallNativeDevMenuHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRInstallNativeDevMenuHooks(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WAGRInstallNativeDevMenuHooks(); });
    }
}
