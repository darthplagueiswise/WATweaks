// WAGRDebugBuildHooks.xm
//
// ABI-correct build-type override owned by the unified
// Employee / Internal / Tester / Dogfood master. The Kotlin bridge exposes
// KmpAppleBuildInfo -getBuildType as an Objective-C object getter (@16@0:8).
// WASDEKotlinSelectorsHolder -isDebugBuild is metadata forwarding and is not a
// BOOL target. WABuildTypeValue is intentionally not fishhooked: Capstone tied
// its direct executable consumer to build-type telemetry, not the AB Props row.

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

static const char *WAGRSkipBuildTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMethodReturnsObjectWithNoExplicitArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return WAGRSkipBuildTypeQualifiers(returnType)[0] == '@';
}

static id WAGRResolveKmpDebugBuildType(void) {
    Class buildTypeClass = objc_getClass("WASDEKmpBuildType");
    SEL debugSelector = sel_registerName("debug");
    Method debugMethod = buildTypeClass
        ? class_getClassMethod(buildTypeClass, debugSelector)
        : NULL;
    if (!WAGRMethodReturnsObjectWithNoExplicitArguments(debugMethod)) {
        gWAGRLastForcedBuildType =
            @"WASDEKmpBuildType +debug unavailable or ABI changed";
        return nil;
    }

    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)((id)buildTypeClass,
                                                   debugSelector);
        gWAGRLastForcedBuildType = value
            ? [NSString stringWithFormat:@"%@ · %@",
                NSStringFromClass([value class]) ?: @"unknown",
                [value description] ?: @"?"]
            : @"debug enum returned nil";
        return value;
    } @catch (NSException *exception) {
        gWAGRLastForcedBuildType = [NSString stringWithFormat:
            @"exception %@: %@", exception.name ?: @"?",
            exception.reason ?: @"?"];
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
        @"KmpAppleBuildInfo=%@\nWASDEKmpBuildType=%@\ngetBuildTypeHook=%@\nmasterForceDebug=%@\nlastForced=%@\nWABuildTypeValue fishhook=DISABLED (telemetry consumer only)",
        infoClass ? @"YES" : @"NO",
        typeClass ? @"YES" : @"NO",
        gWAGRDebugBuildHookInstalled ? @"YES" : @"NO",
        WAGRDebugBuildOverrideEnabled() ? @"YES" : @"NO",
        gWAGRLastForcedBuildType ?: @"none"];
}

extern "C" NSString *WAGRBuildTypeDiagnosticText(void) {
    return WAGRDebugBuildDiagnosticText();
}

__attribute__((constructor))
static void WAGRDebugBuildCtor(void) {
    @autoreleasepool {
        if (!WAGRDebugBuildOverrideEnabled()) return;
        WAGRDebugBuildEnsureInstalled();
    }
}
