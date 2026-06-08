// WAGRContextMenuPipelineProbe.xm
// Diagnostic-only mapper for WhatsApp's native context-menu construction path.
//
// This file intentionally does NOT instantiate WAContextMenuController directly.
// It hooks the objects WhatsApp uses when a real message/cell context menu is
// built naturally, then records the last valid chain for inspection:
//
//   WAMessageContainerViewNavigationControllerProvider
//     -> WAContextMenuPresenter
//     -> WAMessageContextMenuBuilder
//     -> WAContextMenuMain.ContextMenuViewModel / WAContextMenuController
//
// The goal is to map the nil-contextMenuView failures without forcing a fake
// controller open path.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

static BOOL gProbeAttempted = NO;
static NSUInteger gProbeInstalled = 0;
static NSUInteger gProviderInitCount = 0;
static NSUInteger gProviderProvideCount = 0;
static NSUInteger gBuilderInitCount = 0;
static NSUInteger gBuilderMenuCount = 0;
static NSUInteger gPresenterInitCount = 0;
static NSUInteger gPresenterPresentCount = 0;
static NSUInteger gControllerInitCount = 0;
static NSString *gLastProviderClass = nil;
static NSString *gLastProviderHost = nil;
static NSString *gLastBuilderClass = nil;
static NSString *gLastBuilderTitle = nil;
static NSString *gLastPresenterClass = nil;
static NSString *gLastPresenterArgs = nil;
static NSString *gLastControllerClass = nil;
static NSString *gLastThreadSessionIdentifier = nil;
static NSString *gLastMessageClass = nil;
static NSString *gLastUserContextClass = nil;
static NSString *gLastEntryPoint = nil;
static NSString *gLastUISurface = nil;
static NSString *gLastError = nil;

static id (*origProviderInitWithVC)(id, SEL, id) = NULL;
static id (*origProviderInitWithNav)(id, SEL, id) = NULL;
static id (*origProviderProvideNav)(id, SEL) = NULL;
static id (*origBuilderInit)(id, SEL, id, id, BOOL) = NULL;
static id (*origBuilderMenuWithTitle)(id, SEL, id) = NULL;
static id (*origPresenterInitFull)(id, SEL, id, id, id, CGRect, id, id, id, BOOL, id, BOOL, BOOL, id, id) = NULL;
static id (*origPresenterInitEdit)(id, SEL, id, id, id, CGRect, id, id, id, BOOL) = NULL;
static void (*origPresenterPresent)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, id, id) = NULL;
static id (*origContextMenuControllerInitA)(id, SEL, id, id, BOOL) = NULL;
static id (*origContextMenuControllerInitB)(id, SEL, id, CGSize, CGSize, id, id, BOOL) = NULL;

static NSString *WAGRClassName(id obj) {
    return obj ? NSStringFromClass([obj class]) : @"nil";
}

static NSString *WAGRShortObject(id obj) {
    if (!obj) return @"nil";
    NSString *cls = WAGRClassName(obj);
    NSString *desc = nil;
    @try { desc = [obj description]; } @catch (__unused id ex) { desc = nil; }
    if (!desc.length || [desc length] > 180) return cls;
    return [NSString stringWithFormat:@"%@ %@", cls, desc];
}

static void WAGRSetLastError(NSString *s) { gLastError = [s copy]; }

static id hookProviderInitWithVC(id self, SEL _cmd, id vc) {
    gProviderInitCount++;
    gLastProviderClass = WAGRClassName(self);
    gLastProviderHost = [@"viewController=" stringByAppendingString:WAGRShortObject(vc)];
    if (origProviderInitWithVC) return origProviderInitWithVC(self, _cmd, vc);
    return self;
}

static id hookProviderInitWithNav(id self, SEL _cmd, id nav) {
    gProviderInitCount++;
    gLastProviderClass = WAGRClassName(self);
    gLastProviderHost = [@"navigationController=" stringByAppendingString:WAGRShortObject(nav)];
    if (origProviderInitWithNav) return origProviderInitWithNav(self, _cmd, nav);
    return self;
}

static id hookProviderProvideNav(id self, SEL _cmd) {
    gProviderProvideCount++;
    id nav = origProviderProvideNav ? origProviderProvideNav(self, _cmd) : nil;
    gLastProviderClass = WAGRClassName(self);
    gLastProviderHost = [@"provided=" stringByAppendingString:WAGRShortObject(nav)];
    return nav;
}

static id hookBuilderInit(id self, SEL _cmd, id handler, id actionsControl, BOOL copyOnly) {
    gBuilderInitCount++;
    gLastBuilderClass = WAGRClassName(self);
    gLastBuilderTitle = [NSString stringWithFormat:@"handler=%@ actionsControl=%@ copyOnly=%@",
                         WAGRShortObject(handler), WAGRShortObject(actionsControl), copyOnly ? @"YES" : @"NO"];
    if (origBuilderInit) return origBuilderInit(self, _cmd, handler, actionsControl, copyOnly);
    return self;
}

static id hookBuilderMenuWithTitle(id self, SEL _cmd, id title) {
    gBuilderMenuCount++;
    gLastBuilderClass = WAGRClassName(self);
    gLastBuilderTitle = [NSString stringWithFormat:@"menuWithTitle=%@", title ?: @"nil"];
    if (origBuilderMenuWithTitle) return origBuilderMenuWithTitle(self, _cmd, title);
    return nil;
}

static id hookPresenterInitFull(id self, SEL _cmd, id arg1, id containerView, id message, CGRect frame, id responder, id userContext, id threadID, BOOL bubbleAnimation, id entryPoint, BOOL askMetaAI, BOOL messagesFolder, id delegate, id uiSurface) {
    gPresenterInitCount++;
    gLastPresenterClass = WAGRClassName(self);
    gLastMessageClass = WAGRClassName(message);
    gLastUserContextClass = WAGRClassName(userContext);
    gLastThreadSessionIdentifier = [threadID respondsToSelector:@selector(description)] ? [threadID description] : WAGRClassName(threadID);
    gLastEntryPoint = [entryPoint respondsToSelector:@selector(description)] ? [entryPoint description] : WAGRClassName(entryPoint);
    gLastUISurface = [uiSurface respondsToSelector:@selector(description)] ? [uiSurface description] : WAGRClassName(uiSurface);
    gLastPresenterArgs = [NSString stringWithFormat:@"container=%@ responder=%@ frame={%.1f,%.1f,%.1f,%.1f} askMetaAI=%@ folder=%@ delegate=%@",
                          WAGRShortObject(containerView), WAGRShortObject(responder), frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height, askMetaAI ? @"YES" : @"NO", messagesFolder ? @"YES" : @"NO", WAGRShortObject(delegate)];
    if (origPresenterInitFull) return origPresenterInitFull(self, _cmd, arg1, containerView, message, frame, responder, userContext, threadID, bubbleAnimation, entryPoint, askMetaAI, messagesFolder, delegate, uiSurface);
    return self;
}

static id hookPresenterInitEdit(id self, SEL _cmd, id arg1, id containerView, id message, CGRect frame, id responder, id userContext, id threadID, BOOL messagesFolder) {
    gPresenterInitCount++;
    gLastPresenterClass = WAGRClassName(self);
    gLastMessageClass = WAGRClassName(message);
    gLastUserContextClass = WAGRClassName(userContext);
    gLastThreadSessionIdentifier = [threadID respondsToSelector:@selector(description)] ? [threadID description] : WAGRClassName(threadID);
    gLastPresenterArgs = [NSString stringWithFormat:@"EDIT container=%@ responder=%@ frame={%.1f,%.1f,%.1f,%.1f} folder=%@",
                          WAGRShortObject(containerView), WAGRShortObject(responder), frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height, messagesFolder ? @"YES" : @"NO"];
    if (origPresenterInitEdit) return origPresenterInitEdit(self, _cmd, arg1, containerView, message, frame, responder, userContext, threadID, messagesFolder);
    return self;
}

static void hookPresenterPresent(id self, SEL _cmd, id from, BOOL reactions, BOOL edit, BOOL snapshot, BOOL fullScreen, id before, id completion) {
    gPresenterPresentCount++;
    gLastPresenterClass = WAGRClassName(self);
    gLastPresenterArgs = [NSString stringWithFormat:@"presentFrom=%@ reactions=%@ edit=%@ snapshot=%@ fullScreen=%@ before=%@ completion=%@",
                          WAGRShortObject(from), reactions ? @"YES" : @"NO", edit ? @"YES" : @"NO", snapshot ? @"YES" : @"NO", fullScreen ? @"YES" : @"NO", WAGRShortObject(before), WAGRShortObject(completion)];
    if (origPresenterPresent) origPresenterPresent(self, _cmd, from, reactions, edit, snapshot, fullScreen, before, completion);
}

static id hookControllerInitA(id self, SEL _cmd, id navProvider, id trait, BOOL preview) {
    gControllerInitCount++;
    gLastControllerClass = WAGRClassName(self);
    gLastProviderClass = WAGRClassName(navProvider);
    if (origContextMenuControllerInitA) return origContextMenuControllerInitA(self, _cmd, navProvider, trait, preview);
    return self;
}

static id hookControllerInitB(id self, SEL _cmd, id navProvider, CGSize constrained, CGSize vcSize, id threadID, id trait, BOOL preview) {
    gControllerInitCount++;
    gLastControllerClass = WAGRClassName(self);
    gLastProviderClass = WAGRClassName(navProvider);
    gLastThreadSessionIdentifier = [threadID respondsToSelector:@selector(description)] ? [threadID description] : WAGRClassName(threadID);
    if (origContextMenuControllerInitB) return origContextMenuControllerInitB(self, _cmd, navProvider, constrained, vcSize, threadID, trait, preview);
    return self;
}

static BOOL WAGRHookInstance(Class cls, NSString *selName, IMP repl, IMP *orig) {
    if (!cls || !selName.length || !repl || !orig || *orig) return NO;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    MSHookMessageEx(cls, sel, repl, orig);
    return *orig != NULL;
}

static NSUInteger WAGRHookClassesForFragment(NSString *fragment, NSString *selName, IMP repl, IMP *orig) {
    if (*orig || !fragment.length) return 0;
    NSUInteger count = 0;
    unsigned int total = 0;
    Class *classes = objc_copyClassList(&total);
    if (!classes) return 0;
    for (unsigned int i = 0; i < total; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name rangeOfString:fragment options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        if (WAGRHookInstance(classes[i], selName, repl, orig)) { count++; break; }
    }
    free(classes);
    return count;
}

extern "C" void WAGRContextMenuPipelineProbeEnsureInstalled(void) {
    gProbeAttempted = YES;
    NSUInteger installed = 0;

    Class provider = NSClassFromString(@"WAMessageContainerViewNavigationControllerProvider");
    if (!provider) provider = NSClassFromString(@"WAMessageSliceViewsBase.WAMessageContainerViewNavigationControllerProvider");
    if (WAGRHookInstance(provider, @"initWithViewController:", (IMP)hookProviderInitWithVC, (IMP *)&origProviderInitWithVC)) installed++;
    if (WAGRHookInstance(provider, @"initWithNavigationController:", (IMP)hookProviderInitWithNav, (IMP *)&origProviderInitWithNav)) installed++;
    if (WAGRHookInstance(provider, @"provideNavigationController", (IMP)hookProviderProvideNav, (IMP *)&origProviderProvideNav)) installed++;

    Class builder = NSClassFromString(@"WAMessageContextMenuBuilder");
    if (!builder) builder = NSClassFromString(@"WAContextMenuMain.MessageContextMenuBuilder");
    if (WAGRHookInstance(builder, @"initWithActionHandler:actionsControl:copyOnly:", (IMP)hookBuilderInit, (IMP *)&origBuilderInit)) installed++;
    if (WAGRHookInstance(builder, @"menuWithTitle:", (IMP)hookBuilderMenuWithTitle, (IMP *)&origBuilderMenuWithTitle)) installed++;

    Class presenter = NSClassFromString(@"WAContextMenuPresenter");
    if (!presenter) presenter = NSClassFromString(@"WAContextMenuMain.ContextMenuPresenter");
    if (WAGRHookInstance(presenter, @"initWith:containerView:message:frame:responder:userContext:threadSessionIdentifier:messageBubbleAnimationOn:entryPoint:shouldShowAskMetaAI:isOnMessagesFolderView:presenterDelegate:uiSurface:", (IMP)hookPresenterInitFull, (IMP *)&origPresenterInitFull)) installed++;
    if (WAGRHookInstance(presenter, @"initForEditModeWith:containerView:message:frame:responder:userContext:threadSessionIdentifier:isOnMessagesFolderView:", (IMP)hookPresenterInitEdit, (IMP *)&origPresenterInitEdit)) installed++;
    if (WAGRHookInstance(presenter, @"presentFrom:shouldShowReactionsTray:needToTransitToMessageEdit:shouldSnapshotContextView:presentsOverFullScreen:performBeforePresenting:longPressCompletionForReactionsTray:", (IMP)hookPresenterPresent, (IMP *)&origPresenterPresent)) installed++;

    Class controller = NSClassFromString(@"WAContextMenuController");
    if (!controller) controller = NSClassFromString(@"WAContextMenuMain.ContextMenuController");
    if (WAGRHookInstance(controller, @"initWithNavigationControllerProvider:traitCollection:isContextMenuPreview:", (IMP)hookControllerInitA, (IMP *)&origContextMenuControllerInitA)) installed++;
    if (WAGRHookInstance(controller, @"initWithNavigationControllerProvider:constrainedSize:viewControllerSize:threadSessionIdentifier:traitCollection:isContextMenuPreview:", (IMP)hookControllerInitB, (IMP *)&origContextMenuControllerInitB)) installed++;

    // Swift names may be namespaced; fall back to a narrow class-fragment lookup.
    installed += WAGRHookClassesForFragment(@"NavigationControllerProvider", @"provideNavigationController", (IMP)hookProviderProvideNav, (IMP *)&origProviderProvideNav);
    installed += WAGRHookClassesForFragment(@"MessageContextMenuBuilder", @"menuWithTitle:", (IMP)hookBuilderMenuWithTitle, (IMP *)&origBuilderMenuWithTitle);
    installed += WAGRHookClassesForFragment(@"ContextMenuPresenter", @"presentFrom:shouldShowReactionsTray:needToTransitToMessageEdit:shouldSnapshotContextView:presentsOverFullScreen:performBeforePresenting:longPressCompletionForReactionsTray:", (IMP)hookPresenterPresent, (IMP *)&origPresenterPresent);

    gProbeInstalled += installed;
    if (!installed && !gLastError.length) WAGRSetLastError(@"no context-menu pipeline selectors hookable yet");
    else if (installed) WAGRSetLastError(nil);
}

extern "C" NSString *WAGRContextMenuPipelineProbeDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"attempted=%@\ninstalled=%lu\nproviderInit=%lu\nproviderProvide=%lu\nbuilderInit=%lu\nbuilderMenu=%lu\npresenterInit=%lu\npresenterPresent=%lu\ncontrollerInit=%lu\n\nlastProvider=%@\nlastProviderHost=%@\nlastBuilder=%@\nlastBuilderState=%@\nlastPresenter=%@\nlastPresenterArgs=%@\nlastController=%@\nlastMessage=%@\nlastUserContext=%@\nlastThread=%@\nlastEntryPoint=%@\nlastUISurface=%@\nlastError=%@",
            gProbeAttempted ? @"YES" : @"NO",
            (unsigned long)gProbeInstalled,
            (unsigned long)gProviderInitCount,
            (unsigned long)gProviderProvideCount,
            (unsigned long)gBuilderInitCount,
            (unsigned long)gBuilderMenuCount,
            (unsigned long)gPresenterInitCount,
            (unsigned long)gPresenterPresentCount,
            (unsigned long)gControllerInitCount,
            gLastProviderClass ?: @"n/a",
            gLastProviderHost ?: @"n/a",
            gLastBuilderClass ?: @"n/a",
            gLastBuilderTitle ?: @"n/a",
            gLastPresenterClass ?: @"n/a",
            gLastPresenterArgs ?: @"n/a",
            gLastControllerClass ?: @"n/a",
            gLastMessageClass ?: @"n/a",
            gLastUserContextClass ?: @"n/a",
            gLastThreadSessionIdentifier ?: @"n/a",
            gLastEntryPoint ?: @"n/a",
            gLastUISurface ?: @"n/a",
            gLastError ?: @"none"];
}

// startup is coordinated by WAGRBootstrap.xm
static void WAGRContextMenuPipelineProbeCtor(void) {
    // Watusi-aligned policy: constructors may install fixed hooks, but must not
    // run diagnostic runtime probes. This probe is intentionally inert during
    // dylib load and remains available on demand from Settings/debug screens.
}
