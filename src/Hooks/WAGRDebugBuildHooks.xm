// WAGRDebugBuildHooks.xm
// LIEF/Capstone confirmed global build-type source for this WhatsApp build:
// _TtC21WAAppStateSyncContext17KmpAppleBuildInfo -getBuildType (@16@0:8)
// The original concrete implementation sends +[WASDEKmpBuildType release_].
// Force the equivalent +debug enum only while Employee / Internal is enabled.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <string.h>
#import "../WAGramPrefix.h"

typedef id (*WAGRGetBuildTypeIMP)(id, SEL);

static WAGRGetBuildTypeIMP gWAGROrigGetBuildType = NULL;
static BOOL gWAGRDebugBuildHookInstalled = NO;
static NSString *gWAGRLastForcedBuildType = nil;

static BOOL WAGRDebugBuildOverrideEnabled(void) {
    if (WAGRPref(kWAGREmployeeMaster)) return YES;
    return WAGRGateIsSet(@"isDebugBuild") &&
           WAGRGateGet(@"isDebugBuild");
}

static BOOL WAGRMethodReturnsObjectWithNoExplicitArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *cursor = returnType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor == '@';
}

static id WAGRResolveKmpDebugBuildType(void) {
    Class buildTypeClass = objc_getClass("WASDEKmpBuildType");
    if (!buildTypeClass) return nil;

    SEL debugSelector = sel_registerName("debug");
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)((id)buildTypeClass,
                                                   debugSelector);
        if (value) {
            gWAGRLastForcedBuildType = [NSString stringWithFormat:@"%@ · %@",
                NSStringFromClass([value class]) ?: @"unknown",
                [value description] ?: @"?"];
        }
        return value;
    } @catch (NSException *exception) {
        gWAGRLastForcedBuildType = [NSString stringWithFormat:@"exception %@: %@",
            exception.name ?: @"?", exception.reason ?: @"?"];
        return nil;
    }
}

static id WAGRHookGetBuildType(id self, SEL _cmd) {
    if (WAGRDebugBuildOverrideEnabled()) {
        id debugType = WAGRResolveKmpDebugBuildType();
        if (debugType) return debugType;
    }
    return gWAGROrigGetBuildType
        ? gWAGROrigGetBuildType(self, _cmd)
        : nil;
}

extern "C" void WAGRDebugBuildEnsureInstalled(void) {
    if (gWAGRDebugBuildHookInstalled) return;

    Class cls = objc_getClass(
        "_TtC21WAAppStateSyncContext17KmpAppleBuildInfo");
    SEL selector = sel_registerName("getBuildType");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!WAGRMethodReturnsObjectWithNoExplicitArguments(method)) {
        NSLog(@"[WATweaks][DebugBuild] KmpAppleBuildInfo -getBuildType unavailable or ABI changed");
        return;
    }

    IMP original = NULL;
    MSHookMessageEx(cls,
                    selector,
                    (IMP)WAGRHookGetBuildType,
                    &original);
    if (!original || original == (IMP)WAGRHookGetBuildType) {
        NSLog(@"[WATweaks][DebugBuild] failed to install getBuildType hook");
        return;
    }

    gWAGROrigGetBuildType = (WAGRGetBuildTypeIMP)original;
    gWAGRDebugBuildHookInstalled = YES;
    NSLog(@"[WATweaks][DebugBuild] installed KmpAppleBuildInfo -getBuildType");
}

extern "C" NSString *WAGRDebugBuildDiagnosticText(void) {
    Class infoClass = objc_getClass(
        "_TtC21WAAppStateSyncContext17KmpAppleBuildInfo");
    Class typeClass = objc_getClass("WASDEKmpBuildType");
    return [NSString stringWithFormat:
        @"KmpAppleBuildInfo=%@\nWASDEKmpBuildType=%@\ngetBuildTypeHook=%@\nforceDebug=%@\nlastForced=%@",
        infoClass ? @"YES" : @"NO",
        typeClass ? @"YES" : @"NO",
        gWAGRDebugBuildHookInstalled ? @"YES" : @"NO",
        WAGRDebugBuildOverrideEnabled() ? @"YES" : @"NO",
        gWAGRLastForcedBuildType ?: @"none"];
}

__attribute__((constructor))
static void WAGRDebugBuildCtor(void) {
    @autoreleasepool {
        if (!WAGRDebugBuildOverrideEnabled()) return;
        WAGRDebugBuildEnsureInstalled();
    }
}
