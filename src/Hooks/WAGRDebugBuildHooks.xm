// WAGRDebugBuildHooks.xm
//
// Two build-type sources coexist in this WhatsApp build:
//
// 1. _TtC21WAAppStateSyncContext17KmpAppleBuildInfo -getBuildType
//    Objective-C object return (@16@0:8). The Kotlin selector metadata exposes
//    WASDEKmpBuildType.debug / release_. This hook is live and ABI-specific.
//
// 2. WABuildTypeValue(void), exported by SharedModules and imported by the main
//    executable. Capstone shows an integer return: 0 when ConfigType is absent,
//    2 for Beta and 3 for the other explicit ConfigType path (Debug). Because
//    this is an imported C function, fishhook is latched once at launch and
//    changing its preference requires restarting WhatsApp.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdint.h>
#include <string.h>
#import "../WAGramPrefix.h"
#import "../../modules/fishhook/fishhook.h"

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void);

typedef id (*WAGRGetBuildTypeIMP)(id, SEL);
typedef uint64_t (*WAGRBuildTypeValueIMP)(void);

static WAGRGetBuildTypeIMP gWAGROrigGetBuildType = NULL;
static WAGRBuildTypeValueIMP gWAGROrigBuildTypeValue = NULL;
static BOOL gWAGRDebugBuildHookInstalled = NO;
static BOOL gWAGRCBuildTypeLatched = NO;
static BOOL gWAGRCBuildTypeRebound = NO;
static NSString *gWAGRLastForcedBuildType = nil;

static BOOL WAGRDebugBuildObjectOverrideEnabled(void) {
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
    if (!buildTypeClass) {
        gWAGRLastForcedBuildType = @"WASDEKmpBuildType unavailable";
        return nil;
    }

    // Kotlin/Native publishes these names through WASDEKotlinSelectorsHolder;
    // the holder itself is metadata and must never be hooked as a BOOL getter.
    SEL debugSelector = sel_registerName("debug");
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)((id)buildTypeClass,
                                                   debugSelector);
        if (value) {
            gWAGRLastForcedBuildType = [NSString stringWithFormat:@"%@ · %@",
                NSStringFromClass([value class]) ?: @"unknown",
                [value description] ?: @"?"];
        } else {
            gWAGRLastForcedBuildType = @"debug enum returned nil";
        }
        return value;
    } @catch (NSException *exception) {
        gWAGRLastForcedBuildType = [NSString stringWithFormat:@"exception %@: %@",
            exception.name ?: @"?", exception.reason ?: @"?"];
        return nil;
    }
}

static id WAGRHookGetBuildType(id self, SEL _cmd) {
    if (WAGRDebugBuildObjectOverrideEnabled()) {
        id debugType = WAGRResolveKmpDebugBuildType();
        if (debugType) return debugType;
    }
    return gWAGROrigGetBuildType
        ? gWAGROrigGetBuildType(self, _cmd)
        : nil;
}

static uint64_t WAGRHookBuildTypeValue(void) {
    if (gWAGRCBuildTypeLatched) return 3ULL;
    return gWAGROrigBuildTypeValue ? gWAGROrigBuildTypeValue() : 0ULL;
}

static void WAGRInstallCBuildTypeHookIfLatched(void) {
    if (!gWAGRCBuildTypeLatched || gWAGRCBuildTypeRebound) return;
    struct rebinding binding = {
        "WABuildTypeValue",
        (void *)WAGRHookBuildTypeValue,
        (void **)&gWAGROrigBuildTypeValue,
    };
    int result = rebind_symbols(&binding, 1);
    gWAGRCBuildTypeRebound =
        (result == 0 && gWAGROrigBuildTypeValue != NULL);
    NSLog(@"[WATweaks][DebugBuild] WABuildTypeValue fishhook result=%d orig=%p",
          result, (void *)gWAGROrigBuildTypeValue);
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
        @"KmpAppleBuildInfo=%@\nWASDEKmpBuildType=%@\ngetBuildTypeHook=%@\nobjectForceDebug=%@\nlastForced=%@\n\nWABuildTypeValue latched=%@\nfishhook=%@\norig=%p\nforced C value=3",
        infoClass ? @"YES" : @"NO",
        typeClass ? @"YES" : @"NO",
        gWAGRDebugBuildHookInstalled ? @"YES" : @"NO",
        WAGRDebugBuildObjectOverrideEnabled() ? @"YES" : @"NO",
        gWAGRLastForcedBuildType ?: @"none",
        gWAGRCBuildTypeLatched ? @"ON" : @"OFF",
        gWAGRCBuildTypeRebound ? @"YES" : @"NO",
        (void *)gWAGROrigBuildTypeValue];
}

__attribute__((constructor))
static void WAGRDebugBuildCtor(void) {
    @autoreleasepool {
        // The C source is intentionally latched. Employee master also opts in
        // when it was already enabled before this launch; the separate UI toggle
        // permits forcing C build type without enabling every employee gate.
        gWAGRCBuildTypeLatched =
            [[NSUserDefaults standardUserDefaults]
                boolForKey:WA_PREF_FORCE_DEBUG_BUILD] ||
            WAGRPref(kWAGREmployeeMaster);

        BOOL objectEnabled = WAGRDebugBuildObjectOverrideEnabled();
        if (!gWAGRCBuildTypeLatched && !objectEnabled) return;

        WAGRInstallCBuildTypeHookIfLatched();
        if (objectEnabled) WAGRDebugBuildEnsureInstalled();

        // Direct class/selector hooks only. The expensive AB Props scan remains
        // explicit and post-launch.
        WAGRDebugMenuInstrumentationEnsureInstalled();
    }
}
