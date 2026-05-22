#import "WAGRFLEXBridge.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

static id WAGRFLEXSharedManager(void) {
    // First use the FLEXing/libFLEX shim when FLEX is compiled into WATweaks.
    id (*getManager)(void) = (id (*)(void))dlsym(RTLD_DEFAULT, "FLXGetManager");
    if (getManager) {
        id manager = getManager();
        if (manager) return manager;
    }

    // Fallback for external/injected FLEX builds.
    Class cls = NSClassFromString(@"FLEXManager");
    if (!cls || ![cls respondsToSelector:@selector(sharedManager)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(sharedManager));
}

BOOL WAGRFLEXIsAvailable(void) {
    return WAGRFLEXSharedManager() != nil;
}

BOOL WAGRFLEXShowExplorer(NSString **errorText) {
    id manager = WAGRFLEXSharedManager();
    if (!manager) {
        if (errorText) *errorText = @"FLEXManager is not loaded. Bundle/link FLEX.framework or libFLEX into the app first.";
        return NO;
    }

    SEL (*revealSEL)(void) = (SEL (*)(void))dlsym(RTLD_DEFAULT, "FLXRevealSEL");
    SEL show = revealSEL ? revealSEL() : NSSelectorFromString(@"showExplorer");
    SEL toggle = NSSelectorFromString(@"toggleExplorer");
    if ([manager respondsToSelector:show]) {
        ((void (*)(id, SEL))objc_msgSend)(manager, show);
        return YES;
    }
    if ([manager respondsToSelector:toggle]) {
        ((void (*)(id, SEL))objc_msgSend)(manager, toggle);
        return YES;
    }

    if (errorText) *errorText = @"FLEXManager loaded, but showExplorer/toggleExplorer is unavailable.";
    return NO;
}

BOOL WAGRFLEXExploreObject(id object, NSString **errorText) {
    if (!object) {
        if (errorText) *errorText = @"No object to explore.";
        return NO;
    }

    id manager = WAGRFLEXSharedManager();
    if (!manager) {
        if (errorText) *errorText = @"FLEXManager is not loaded. Cannot explore object.";
        return NO;
    }

    NSArray<NSString *> *selectors = @[
        @"exploreObject:",
        @"showExplorerForObject:",
        @"presentObjectExplorerForObject:"
    ];

    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([manager respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(manager, sel, object);
            return YES;
        }
    }

    // Fall back to opening global FLEX explorer. The user can then search the
    // class/object manually through FLEX's own browser.
    return WAGRFLEXShowExplorer(errorText);
}

NSString *WAGRFLEXDiagnosticText(void) {
    Class cls = NSClassFromString(@"FLEXManager");
    id manager = WAGRFLEXSharedManager();
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"FLEXManager class=%@", cls ? @"YES" : @"NO"]];
    [lines addObject:[NSString stringWithFormat:@"sharedManager=%@", manager ? @"YES" : @"NO"]];
    if (manager) {
        [lines addObject:[NSString stringWithFormat:@"showExplorer=%@", [manager respondsToSelector:NSSelectorFromString(@"showExplorer")] ? @"YES" : @"NO"]];
        [lines addObject:[NSString stringWithFormat:@"toggleExplorer=%@", [manager respondsToSelector:NSSelectorFromString(@"toggleExplorer")] ? @"YES" : @"NO"]];
        [lines addObject:[NSString stringWithFormat:@"exploreObject=%@", [manager respondsToSelector:NSSelectorFromString(@"exploreObject:")] ? @"YES" : @"NO"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}
