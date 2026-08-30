// WAGRNativeDevMenuHooks.xm
// ─────────────────────────────────────────────────────────────────────────────
// Single owner of the hooks that unlock WhatsApp's native Developer Menu.
// Constructor path is Watusi-style: fixed class/selector lookups + hook install
// only. State reads go through WAGRGateStore/WAGRPref; no legacy override-key
// storage is used here.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRLog.h"

// ── Original IMPs ────────────────────────────────────────────────────────────
typedef BOOL (*BoolIMP)(id, SEL);
typedef id   (*IDIMP)(id, SEL);
typedef id   (*InitCtxIMP)(id, SEL, id);

extern "C" void WAGRRememberUserContext(id ctx, NSString *source);
extern "C" id WAGRCurrentUserContext(void);
extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void);
extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void);

static BoolIMP orig_dmAllowed = NULL;
static BoolIMP orig_dmShortcutEnabled = NULL;
static IDIMP orig_debugVCUserContext = NULL;
static InitCtxIMP orig_debugVCInitWithUserContext = NULL;
static InitCtxIMP orig_privateExpInitWithUserContext = NULL;
typedef void (*VoidIMP)(id, SEL);
static VoidIMP orig_debugVCCreateSections = NULL;

static BOOL gDevMenuHooked  = NO;
static BOOL gShortcutHooked = NO;
static BOOL gDebugVCHooked = NO;
static BOOL gPrivateExpVCHooked = NO;
static BOOL gDebugABPropsSectionHooked = NO;


// WhatsApp 26.33: the RC Developer controller compiles the yellow AB Props
// placeholder directly into -createSections. There is no nil-driven branch to
// flip. The complete native AB/private-experimentation UI lives in
// WAPrivateExperimentationViews.PrivateExperimentationDebugViewController.
// Its initWithUserContext: asks WAContextObjectProvider for its manager and that
// native initializer resolves userContext.privateABProperties. WATweaks only
// replaces the compiled RC placeholder row with a native WATableRow navigation
// entry; the destination controller, model, fetch and ABProps implementation are
// all WhatsApp-owned.
static NSString * const kWAGRNativeDeveloperABPropsWiringSchema = @"watweaks_native_developer_abprops_wiring_v26_33";

extern "C" void WAGRContextSpyInstallForObject(id obj);

static BOOL WAGRNativeMethodEncodingMatches(Class cls, SEL selector, const char *expected) {
    if (!cls || !selector || !expected) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && strcmp(encoding, expected) == 0;
}

static id WAGRNativeObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (!WAGRNativeMethodEncodingMatches([target class], selector, "@16@0:8")) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRNativeVoidObjectArg(id target, NSString *selectorName, id value) {
    if (!target || !selectorName.length) return;
    SEL selector = NSSelectorFromString(selectorName);
    if (!WAGRNativeMethodEncodingMatches([target class], selector, "v24@0:8@16")) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value); }
    @catch (__unused NSException *exception) {}
}

static Class WAGRPrivateExperimentationDebugControllerClass(void) {
    Class cls = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
    if (!cls) cls = NSClassFromString(@"WAPrivateExperimentationViews.PrivateExperimentationDebugViewController");
    if (!cls) cls = NSClassFromString(@"WAPrivateExperimentation.PrivateExperimentationDebugViewController");
    return cls;
}

static NSString *WAGRPrivateExperimentationRuntimeMetadata(Class cls) {
    Ivar managerIvar = cls ? class_getInstanceVariable(cls, "experimentManager") : NULL;
    Ivar contextIvar = cls ? class_getInstanceVariable(cls, "userContext") : NULL;
    ptrdiff_t managerOffset = managerIvar ? ivar_getOffset(managerIvar) : -1;
    ptrdiff_t contextOffset = contextIvar ? ivar_getOffset(contextIvar) : -1;
    return [NSString stringWithFormat:@"class=%@ experimentManagerOff=%@ userContextOff=%@ initABI=%@",
        cls ? (NSStringFromClass(cls) ?: @"?") : @"nil",
        managerIvar ? [NSString stringWithFormat:@"0x%tx", managerOffset] : @"missing",
        contextIvar ? [NSString stringWithFormat:@"0x%tx", contextOffset] : @"missing",
        cls && class_getInstanceMethod(cls, NSSelectorFromString(@"initWithUserContext:"))
            ? [NSString stringWithUTF8String:method_getTypeEncoding(class_getInstanceMethod(cls, NSSelectorFromString(@"initWithUserContext:"))) ?: "?"]
            : @"missing"];
}

static id WAGRNativePrivateABProperties(id userContext) {
    if (!userContext) return nil;
    WAGRContextSpyInstallForObject(userContext);
    SEL selector = NSSelectorFromString(@"privateABProperties");
    if (!WAGRNativeMethodEncodingMatches([userContext class], selector, "@16@0:8")) {
        WAGRLogAppendF(@"[DeveloperABProps] %@ has no compatible privateABProperties getter",
                       NSStringFromClass([userContext class]));
        return nil;
    }
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(userContext, selector);
        WAGRLogAppendF(@"[DeveloperABProps] privateABProperties=%@ (%p)",
                       value ? NSStringFromClass([value class]) : @"nil", (__bridge void *)value);
        return value;
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[DeveloperABProps] privateABProperties threw %@: %@", exception.name, exception.reason);
        return nil;
    }
}

static id WAGRDebugControllerUserContext(id debugController) {
    id context = WAGRNativeObjectNoArg(debugController, @"userContext");
    if (!context) context = WAGRCurrentUserContext();
    if (context) {
        WAGRRememberUserContext(context, @"Developer AB Props native navigation");
        WAGRContextSpyInstallForObject(context);
    }
    return context;
}

static void WAGRPresentNativeDeveloperABPropsError(id debugController, NSString *message) {
    if (![debugController isKindOfClass:UIViewController.class]) return;
    UIViewController *owner = (UIViewController *)debugController;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AB Props"
        message:message ?: @"Native Private Experimentation could not be initialized."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static void WAGROpenNativePrivateExperimentation(id debugController) {
    void (^openBlock)(void) = ^{
        id context = WAGRDebugControllerUserContext(debugController);
        Class cls = WAGRPrivateExperimentationDebugControllerClass();
        WAGRLogAppendF(@"[DeveloperABProps] open schema=%@ context=%@ (%p) %@",
                       kWAGRNativeDeveloperABPropsWiringSchema,
                       context ? NSStringFromClass([context class]) : @"nil",
                       (__bridge void *)context,
                       WAGRPrivateExperimentationRuntimeMetadata(cls));

        if (!context || !cls || !WAGRNativeMethodEncodingMatches(cls, NSSelectorFromString(@"initWithUserContext:"), "@24@0:8@16")) {
            WAGRPresentNativeDeveloperABPropsError(debugController, @"WhatsApp's native Private Experimentation controller or account userContext is unavailable.");
            return;
        }

        // Preflight the exact dependency consumed by the native Swift manager.
        // This does not replace the model; initWithUserContext: will resolve it
        // again through WAContextObjectProvider as in WhatsApp's own path.
        id privateProps = WAGRNativePrivateABProperties(context);
        if (!privateProps) {
            WAGRPresentNativeDeveloperABPropsError(debugController, @"WAContextMain.privateABProperties returned nil. See WATweaks diagnostics for the exact dependency that failed.");
            return;
        }

        id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
        id controller = nil;
        @try {
            controller = ((id (*)(id, SEL, id))objc_msgSend)(allocated, NSSelectorFromString(@"initWithUserContext:"), context);
        } @catch (NSException *exception) {
            WAGRLogAppendF(@"[DeveloperABProps] native init threw %@: %@", exception.name, exception.reason);
        }
        if (![controller isKindOfClass:UIViewController.class]) {
            WAGRPresentNativeDeveloperABPropsError(debugController, @"Native Private Experimentation returned no view controller.");
            return;
        }

        WAGRLogAppendF(@"[DeveloperABProps] native controller initialized=%@ (%p)",
                       NSStringFromClass([controller class]), (__bridge void *)controller);
        UIViewController *owner = [debugController isKindOfClass:UIViewController.class] ? (UIViewController *)debugController : nil;
        UINavigationController *navigation = owner.navigationController;
        if (navigation) {
            [navigation pushViewController:(UIViewController *)controller animated:YES];
            WAGRLogAppend(@"[DeveloperABProps] pushed native Private Experimentation controller");
        } else if (owner) {
            [owner presentViewController:(UIViewController *)controller animated:YES completion:nil];
            WAGRLogAppend(@"[DeveloperABProps] presented native Private Experimentation controller");
        }
    };
    if (NSThread.isMainThread) openBlock();
    else dispatch_async(dispatch_get_main_queue(), openBlock);
}

static BOOL WAGRWireNativeDeveloperABPropsSection(id debugController) {
    id sections = WAGRNativeObjectNoArg(debugController, @"sections");
    if (!sections || ![sections conformsToProtocol:@protocol(NSFastEnumeration)]) {
        WAGRLogAppend(@"[DeveloperABProps] native sections collection unavailable");
        return NO;
    }

    for (id section in sections) {
        NSString *header = WAGRNativeObjectNoArg(section, @"headerText");
        if (![header isKindOfClass:NSString.class] || ![header isEqualToString:@"AB Props"]) continue;

        SEL addSelector = NSSelectorFromString(@"addTableRowWithCellStyle:");
        Method addMethod = class_getInstanceMethod([section class], addSelector);
        const char *addEncoding = addMethod ? method_getTypeEncoding(addMethod) : NULL;
        id row = nil;
        if (addEncoding && strcmp(addEncoding, "@24@0:8q16") == 0) {
            row = ((id (*)(id, SEL, NSInteger))objc_msgSend)(section, addSelector, UITableViewCellStyleSubtitle);
        } else {
            row = WAGRNativeObjectNoArg(section, @"addDefaultTableRow");
        }
        if (!row) {
            WAGRLogAppend(@"[DeveloperABProps] WATableSection could not create a native row");
            return NO;
        }

        id cellObject = WAGRNativeObjectNoArg(row, @"cell");
        if ([cellObject isKindOfClass:UITableViewCell.class]) {
            UITableViewCell *cell = (UITableViewCell *)cellObject;
            cell.textLabel.text = @"Private Experimentation Debug";
            cell.detailTextLabel.text = @"Native WAABProperties / privateABProperties";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }

        __weak id weakDebugController = debugController;
        void (^handler)(void) = ^{
            id strongDebugController = weakDebugController;
            if (strongDebugController) WAGROpenNativePrivateExperimentation(strongDebugController);
        };
        SEL handlerSelector = NSSelectorFromString(@"setHandler:");
        Method handlerMethod = class_getInstanceMethod([row class], handlerSelector);
        const char *handlerEncoding = handlerMethod ? method_getTypeEncoding(handlerMethod) : NULL;
        if (!handlerEncoding || strcmp(handlerEncoding, "v24@0:8@?16") != 0) {
            WAGRLogAppendF(@"[DeveloperABProps] WATableRow setHandler ABI mismatch: %s", handlerEncoding ?: "missing");
            return NO;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(row, handlerSelector, [handler copy]);

        // addTableRow... temporarily appends to the RC placeholder rows. Make
        // the new native navigation row the only row and clear the RC-only tip.
        WAGRNativeVoidObjectArg(section, @"setRows:", @[row]);
        WAGRNativeVoidObjectArg(section, @"setFooterText:", nil);
        WAGRNativeVoidObjectArg(section, @"setFooterView:", nil);

        WAGRLogAppendF(@"[DeveloperABProps] replaced compiled RC placeholder with native Private Experimentation row; schema=%@",
                       kWAGRNativeDeveloperABPropsWiringSchema);
        return YES;
    }

    WAGRLogAppend(@"[DeveloperABProps] AB Props section not found after original createSections");
    return NO;
}

static void hookDebugVCCreateSections(id self, SEL _cmd) {
    if (orig_debugVCCreateSections) orig_debugVCCreateSections(self, _cmd);
    WAGRWireNativeDeveloperABPropsSection(self);
}

static BOOL WAGRGateForcedOn(NSString *selectorName) {
    return selectorName.length && WAGRGateIsSet(selectorName) && WAGRGateGet(selectorName);
}


// ── Real userContext capture ────────────────────────────────────────────────
// WADebugViewController is the reliable native owner. When WhatsApp creates it
// through DebugMenuProvider it passes the account/session-bound userContext.
// Cache that object and reuse it for PrivateExperimentationDebugViewController.
static id hookDebugVCInitWithUserContext(id self, SEL _cmd, id ctx) {
    if (ctx) {
        WAGRLogAppendF(@"[DebugVC] initWithUserContext arg=%@ (%p)", NSStringFromClass([ctx class]), (__bridge void *)ctx);
        WAGRRememberUserContext(ctx, @"WADebugViewController initWithUserContext: arg");
    }
    id result = orig_debugVCInitWithUserContext ? orig_debugVCInitWithUserContext(self, _cmd, ctx) : self;
    if (ctx) WAGRRememberUserContext(ctx, @"WADebugViewController initWithUserContext: result");
    return result;
}

static id hookDebugVCUserContext(id self, SEL _cmd) {
    id ctx = orig_debugVCUserContext ? orig_debugVCUserContext(self, _cmd) : nil;
    if (ctx) {
        WAGRLogAppendF(@"[DebugVC] userContext getter=%@ (%p)", NSStringFromClass([ctx class]), (__bridge void *)ctx);
        WAGRRememberUserContext(ctx, @"WADebugViewController userContext getter");
    }
    return ctx;
}

static id hookPrivateExpInitWithUserContext(id self, SEL _cmd, id ctx) {
    id realCtx = ctx ?: WAGRCurrentUserContext();
    if (realCtx) {
        WAGRRememberUserContext(realCtx, @"PrivateExperimentation initWithUserContext: arg/cache");
        WAGRContextSpyInstallForObject(realCtx);
    }
    WAGRLogAppendF(@"[PrivateExpVC] native init context=%@ (%p) %@",
                   realCtx ? NSStringFromClass([realCtx class]) : @"nil",
                   (__bridge void *)realCtx,
                   WAGRPrivateExperimentationRuntimeMetadata([self class]));
    return orig_privateExpInitWithUserContext
        ? orig_privateExpInitWithUserContext(self, _cmd, realCtx)
        : self;
}

static void installUserContextCaptureHooks(void) {
    Class dbg = NSClassFromString(@"WADebugViewController");
    if (dbg) {
        if (!orig_debugVCInitWithUserContext) {
            SEL initSel = NSSelectorFromString(@"initWithUserContext:");
            if (WAGRNativeMethodEncodingMatches(dbg, initSel, "@24@0:8@16")) {
                MSHookMessageEx(dbg, initSel, (IMP)hookDebugVCInitWithUserContext, (IMP *)&orig_debugVCInitWithUserContext);
            }
        }
        if (!orig_debugVCUserContext) {
            SEL ctxSel = NSSelectorFromString(@"userContext");
            if (WAGRNativeMethodEncodingMatches(dbg, ctxSel, "@16@0:8")) {
                MSHookMessageEx(dbg, ctxSel, (IMP)hookDebugVCUserContext, (IMP *)&orig_debugVCUserContext);
            }
        }
        if (!gDebugABPropsSectionHooked) {
            SEL createSel = NSSelectorFromString(@"createSections");
            if (WAGRNativeMethodEncodingMatches(dbg, createSel, "v16@0:8")) {
                MSHookMessageEx(dbg, createSel, (IMP)hookDebugVCCreateSections, (IMP *)&orig_debugVCCreateSections);
                gDebugABPropsSectionHooked = (orig_debugVCCreateSections != NULL);
                WAGRLogAppendF(@"[DeveloperABProps] createSections hook=%@ ABI=v16@0:8",
                               gDebugABPropsSectionHooked ? @"installed" : @"failed");
            } else {
                WAGRLogAppend(@"[DeveloperABProps] WADebugViewController createSections ABI mismatch");
            }
        }
        gDebugVCHooked = (orig_debugVCInitWithUserContext != NULL || orig_debugVCUserContext != NULL || gDebugABPropsSectionHooked);
    }

    if (!gPrivateExpVCHooked) {
        Class pe = WAGRPrivateExperimentationDebugControllerClass();
        if (pe) {
            SEL initSel = NSSelectorFromString(@"initWithUserContext:");
            if (WAGRNativeMethodEncodingMatches(pe, initSel, "@24@0:8@16")) {
                MSHookMessageEx(pe, initSel, (IMP)hookPrivateExpInitWithUserContext, (IMP *)&orig_privateExpInitWithUserContext);
                gPrivateExpVCHooked = (orig_privateExpInitWithUserContext != NULL);
            }
        }
    }
}


// ── WAContextMain / userContext spy ─────────────────────────────────────────
// Diagnostic-only. We hook only selectors that actually exist on the captured
// runtime context class. This tells us whether PrivateExperimentationManager is
// asking the context for abProperties/privateABProperties/preferences/etc. and
// what comes back. No return values are modified here.
typedef id   (*CtxObjIMP)(id, SEL);
typedef BOOL (*CtxBoolIMP)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *gCtxObjOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gCtxBoolOrig = nil;
static NSMutableSet<NSString *> *gCtxSpyInstalled = nil;


static id WAGRDebugPropOverridesFallback(void) {
    static NSMutableDictionary *fallback = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fallback = [NSMutableDictionary dictionary];
    });
    return fallback;
}

static NSString *WAGRContextSpyKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static NSMutableDictionary<NSString *, NSString *> *gCtxSpyLastSummary = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gCtxSpyLastLogTime = nil;
static NSObject *gCtxSpyLogLock = nil;

static void WAGRContextSpyEnsureLogState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCtxSpyLastSummary = [NSMutableDictionary dictionary];
        gCtxSpyLastLogTime = [NSMutableDictionary dictionary];
        gCtxSpyLogLock = [NSObject new];
    });
}

static BOOL WAGRContextSpyShouldLog(NSString *key, NSString *summary, NSTimeInterval minInterval) {
    if (!key.length) return YES;
    WAGRContextSpyEnsureLogState();
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    @synchronized (gCtxSpyLogLock) {
        NSString *last = gCtxSpyLastSummary[key];
        NSTimeInterval lastTime = [gCtxSpyLastLogTime[key] doubleValue];
        if (last && [last isEqualToString:summary ?: @""] && (now - lastTime) < minInterval) {
            return NO;
        }
        gCtxSpyLastSummary[key] = summary ?: @"";
        gCtxSpyLastLogTime[key] = @(now);
        return YES;
    }
}

static BOOL WAGRContextSpyHookBoolSelector(Class cls, NSString *selectorName);
extern "C" void WAGRContextSpyInstallForObject(id obj);

static id hookContextSpyObject(id self, SEL _cmd) {
    NSString *key = WAGRContextSpyKey([self class], _cmd);
    CtxObjIMP orig = NULL;
    NSValue *v = gCtxObjOrig[key];
    if (v) orig = reinterpret_cast<CtxObjIMP>([v pointerValue]);
    id ret = nil;
    @try { ret = orig ? orig(self, _cmd) : nil; } @catch (__unused NSException *ex) { ret = nil; }
    NSString *selName = NSStringFromSelector(_cmd);
    NSString *clsName = NSStringFromClass([self class]);
    NSString *summary = [NSString stringWithFormat:@"%@:%p",
                         ret ? NSStringFromClass([ret class]) : @"nil",
                         (__bridge void *)ret];
    NSString *logKey = [NSString stringWithFormat:@"obj|%@|%@", clsName, selName];

    if (!ret && [selName isEqualToString:@"debugPropOverrides"]) {
        ret = WAGRDebugPropOverridesFallback();
        summary = [NSString stringWithFormat:@"fallback:%@:%p", NSStringFromClass([ret class]), (__bridge void *)ret];
        if (WAGRContextSpyShouldLog(logKey, summary, 1.0)) {
            WAGRLogAppendF(@"[ContextSpy] %@.%@ -> nil; returning fallback %@ (%p)",
                           clsName, selName,
                           NSStringFromClass([ret class]), (__bridge void *)ret);
        }
    } else if (WAGRContextSpyShouldLog(logKey, summary, 1.0)) {
        WAGRLogAppendF(@"[ContextSpy] %@.%@ -> %@ (%p)",
                       clsName, selName,
                       ret ? NSStringFromClass([ret class]) : @"nil", (__bridge void *)ret);
    }

    // The PrivateExperimentationManager path appears to call isPrimaryDevice on
    // the accountProvider dependency, not on WAContextMain itself. When we see
    // the real provider, install the same diagnostic/force hook there too.
    if (ret && [selName isEqualToString:@"accountProvider"]) {
        WAGRContextSpyInstallForObject(ret);
    }
    return ret;
}

static BOOL hookContextSpyBool(id self, SEL _cmd) {
    NSString *key = WAGRContextSpyKey([self class], _cmd);
    CtxBoolIMP orig = NULL;
    NSValue *v = gCtxBoolOrig[key];
    if (v) orig = reinterpret_cast<CtxBoolIMP>([v pointerValue]);
    BOOL ret = NO;
    @try { ret = orig ? orig(self, _cmd) : NO; } @catch (__unused NSException *ex) { ret = NO; }
    NSString *selName = NSStringFromSelector(_cmd);

    NSString *clsName = NSStringFromClass([self class]);
    NSString *logKey = [NSString stringWithFormat:@"bool|%@|%@", clsName, selName];

    if ([selName isEqualToString:@"isPrimaryDevice"]) {
        NSString *summary = [NSString stringWithFormat:@"%@->forcedYES", ret ? @"YES" : @"NO"];
        if (WAGRContextSpyShouldLog(logKey, summary, 1.0)) {
            WAGRLogAppendF(@"[ContextSpy] %@.%@ -> %@ (forced YES for PrivateExp)",
                           clsName, selName, ret ? @"YES" : @"NO");
        }
        return YES;
    }

    if ([selName isEqualToString:@"isInternalUser"] ||
        [selName isEqualToString:@"isEmployee"] ||
        [selName isEqualToString:@"isMetaEmployeeOrInternalTester"]) {
        BOOL forced = WAGRPref(kWAGRInternalMaster) || WAGRPref(kWAGREmployeeMaster) ||
                      WAGRGateGet(selName) || WAGRGateGet(@"isInternalUser");
        if (forced) {
            NSString *summary = [NSString stringWithFormat:@"%@->forcedYES", ret ? @"YES" : @"NO"];
            if (WAGRContextSpyShouldLog(logKey, summary, 1.0)) {
                WAGRLogAppendF(@"[ContextSpy] %@.%@ -> %@ (forced YES by Internal/Employee master)",
                               clsName, selName, ret ? @"YES" : @"NO");
            }
            return YES;
        }
    }

    NSString *summary = ret ? @"YES" : @"NO";
    if (WAGRContextSpyShouldLog(logKey, summary, 1.0)) {
        WAGRLogAppendF(@"[ContextSpy] %@.%@ -> %@", clsName, selName, ret ? @"YES" : @"NO");
    }
    return ret;
}

static BOOL WAGRContextSpyHookObjectSelector(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) return NO;
    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != '@') return NO;

    NSString *key = WAGRContextSpyKey(cls, sel);
    if ([gCtxSpyInstalled containsObject:key]) return YES;

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)hookContextSpyObject, &orig);
    if (!orig) return NO;
    if (!gCtxObjOrig) gCtxObjOrig = [NSMutableDictionary dictionary];
    if (!gCtxSpyInstalled) gCtxSpyInstalled = [NSMutableSet set];
    gCtxObjOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    [gCtxSpyInstalled addObject:key];
    WAGRLogAppendF(@"[ContextSpy] hooked object selector %@.%@", NSStringFromClass(cls), selectorName);
    return YES;
}

static BOOL WAGRContextSpyHookBoolSelector(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) return NO;
    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'B' && ret[0] != 'c') return NO;

    NSString *key = WAGRContextSpyKey(cls, sel);
    if ([gCtxSpyInstalled containsObject:key]) return YES;

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)hookContextSpyBool, &orig);
    if (!orig) return NO;
    if (!gCtxBoolOrig) gCtxBoolOrig = [NSMutableDictionary dictionary];
    if (!gCtxSpyInstalled) gCtxSpyInstalled = [NSMutableSet set];
    gCtxBoolOrig[key] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)];
    [gCtxSpyInstalled addObject:key];
    WAGRLogAppendF(@"[ContextSpy] hooked bool selector %@.%@", NSStringFromClass(cls), selectorName);
    return YES;
}

extern "C" void WAGRContextSpyInstallForObject(id obj) {
    if (!obj) return;
    if (!gCtxSpyInstalled) gCtxSpyInstalled = [NSMutableSet set];
    Class cls = [obj class];
    if (!cls) return;

    NSUInteger hooked = 0;
    if (WAGRContextSpyHookBoolSelector(cls, @"isPrimaryDevice")) hooked++;
    if (hooked) {
        WAGRLogAppendF(@"[ContextSpy] dependency install class=%@ hookedPrimary=%lu",
                       NSStringFromClass(cls), (unsigned long)hooked);
    }
}

extern "C" void WAGRContextSpyInstallForContext(id ctx) {
    if (!ctx) return;
    if (!gCtxSpyInstalled) gCtxSpyInstalled = [NSMutableSet set];
    Class cls = [ctx class];
    if (!cls) return;

    NSArray<NSString *> *objectSelectors = @[
        @"abProperties",
        @"privateABProperties",
        @"debugPropOverrides",
        @"preferences",
        @"preferencesStore",
        @"accountProvider",
        @"propertiesStore",
        @"mobileConfig",
        @"mobileConfigManager",
        @"waABProperties",
        @"serverProperties"
    ];
    NSArray<NSString *> *boolSelectors = @[
        @"isPrimaryDevice",
        @"isInternalUser",
        @"isEmployee",
        @"isMetaEmployeeOrInternalTester",
        @"isDebugMenuAllowed"
    ];

    NSUInteger hooked = 0;
    for (NSString *sel in objectSelectors) if (WAGRContextSpyHookObjectSelector(cls, sel)) hooked++;
    for (NSString *sel in boolSelectors) if (WAGRContextSpyHookBoolSelector(cls, sel)) hooked++;

    // Proactively hook accountProvider.isPrimaryDevice because the Swift
    // PrivateExperimentationManager constructor calls a helper that resolves
    // selector isPrimaryDevice on one of its injected dependencies. The logs
    // showed WAContextMain.accountProvider is valid while WAContextMain.isPrimaryDevice
    // reports NO.
    @try {
        SEL apSel = NSSelectorFromString(@"accountProvider");
        if ([ctx respondsToSelector:apSel]) {
            id (*fn)(id, SEL) = (id (*)(id, SEL))[ctx methodForSelector:apSel];
            id provider = fn(ctx, apSel);
            if (provider) WAGRContextSpyInstallForObject(provider);
        }
    } @catch (__unused NSException *ex) {}

    WAGRLogAppendF(@"[ContextSpy] install pass class=%@ hookedTotal=%lu", NSStringFromClass(cls), (unsigned long)hooked);
}

// ── Master gate ──────────────────────────────────────────────────────────────
// Returns YES if any relevant master pref or runtime-browser gate is ON.
static BOOL WAGRNativeDevAllowed(void) {
    if (WAGRPref(kWAGRDebugMenuNative)
        || WAGRPref(kWAGRInternalMaster)
        || WAGRPref(kWAGREmployeeMaster)
        || WAGRPref(kWAGRDebugMode)) {
        return YES;
    }

    // Runtime Avançado now writes selector names through WAGRGateStore. Do not
    // use WAGROverrideKey/WAGRHasOverride here: those belonged to the removed
    // duplicated UI/storage path.
    if (WAGRGateForcedOn(@"isDebugMenuAllowed") ||
        WAGRGateForcedOn(@"isDebugMenuShortcutEnabled")) {
        return YES;
    }
    return NO;
}

// ── Trampolines ──────────────────────────────────────────────────────────────
static BOOL hookDevAllowed(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmAllowed ? orig_dmAllowed(self, _cmd) : NO;
}

static BOOL hookDevShortcut(id self, SEL _cmd) {
    if (WAGRNativeDevAllowed()) return YES;
    return orig_dmShortcutEnabled ? orig_dmShortcutEnabled(self, _cmd) : NO;
}

// ── Method presence probes ───────────────────────────────────────────────────
static BOOL classHasInstanceMethod(Class cls, SEL sel) {
    return cls && sel && class_getInstanceMethod(cls, sel) != NULL;
}

static BOOL classHasClassMethod(Class cls, SEL sel) {
    return cls && sel && class_getClassMethod(cls, sel) != NULL;
}

// ── Installer ────────────────────────────────────────────────────────────────
static void installNativeDevMenuHooks(void) {
    installUserContextCaptureHooks();
    WAGRDebugMenuInstrumentationEnsureInstalled();
    if (gDevMenuHooked && gShortcutHooked) return;

    NSArray *candidates = @[
        @"_TtC15WADebugMenuMain17DebugMenuProvider",
        @"WASettingsViewController",
        @"WASettingsTableViewController",
        @"WANewSettingsViewController",
        @"WASettingsNavTableViewController",
        @"WASettingsNavigationController",
    ];

    SEL allowedSel  = NSSelectorFromString(@"isDebugMenuAllowed");
    SEL shortcutSel = NSSelectorFromString(@"isDebugMenuShortcutEnabled");

    for (NSString *n in candidates) {
        Class cls = NSClassFromString(n);
        if (!cls) continue;

        if (!gDevMenuHooked) {
            if (classHasInstanceMethod(cls, allowedSel)) {
                MSHookMessageEx(cls, allowedSel, (IMP)hookDevAllowed, (IMP *)&orig_dmAllowed);
                gDevMenuHooked = (orig_dmAllowed != NULL);
            } else if (classHasClassMethod(cls, allowedSel)) {
                MSHookMessageEx(object_getClass(cls), allowedSel, (IMP)hookDevAllowed, (IMP *)&orig_dmAllowed);
                gDevMenuHooked = (orig_dmAllowed != NULL);
            }
        }

        if (!gShortcutHooked) {
            if (classHasInstanceMethod(cls, shortcutSel)) {
                MSHookMessageEx(cls, shortcutSel, (IMP)hookDevShortcut, (IMP *)&orig_dmShortcutEnabled);
                gShortcutHooked = (orig_dmShortcutEnabled != NULL);
            } else if (classHasClassMethod(cls, shortcutSel)) {
                MSHookMessageEx(object_getClass(cls), shortcutSel, (IMP)hookDevShortcut, (IMP *)&orig_dmShortcutEnabled);
                gShortcutHooked = (orig_dmShortcutEnabled != NULL);
            }
        }

        if (gDevMenuHooked && gShortcutHooked) break;
    }

    WAGRLogAppendF(@"[NativeDevMenu] install pass: allowed=%@ shortcut=%@ debugVCHook=%@ privateExpHook=%@",
          gDevMenuHooked  ? @"YES" : @"NO",
          gShortcutHooked ? @"YES" : @"NO",
          gDebugVCHooked ? @"YES" : @"NO",
          gPrivateExpVCHooked ? @"YES" : @"NO");
}

extern "C" void WAGRNativeDevMenuEnsureHooksInstalled(void) {
    installNativeDevMenuHooks();
}

extern "C" NSString *WAGRNativeDevMenuDiagnosticText(void) {
    Class swiftCls = NSClassFromString(@"_TtC15WADebugMenuMain17DebugMenuProvider");
    Class debugVC = NSClassFromString(@"WADebugViewController");
    Class peVC = NSClassFromString(@"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController");
    return [NSString stringWithFormat:
            @"swiftClassLoaded=%@\nallowedHook=%@\nshortcutHook=%@\ndebugVC=%@\ndebugVCHooks=%@\nprivateExpVC=%@\nprivateExpInitHook=%@\ncachedUserContext=%@\n%@",
            swiftCls ? @"YES" : @"NO",
            gDevMenuHooked  ? @"YES" : @"NO",
            gShortcutHooked ? @"YES" : @"NO",
            debugVC ? @"YES" : @"NO",
            gDebugVCHooked ? @"YES" : @"NO",
            peVC ? @"YES" : @"NO",
            gPrivateExpVCHooked ? @"YES" : @"NO",
            WAGRCurrentUserContext() ? NSStringFromClass([WAGRCurrentUserContext() class]) : @"nil",
            WAGRDebugMenuInstrumentationDiagnosticText() ?: @"DebugMenuSpy n/a"];
}

static void WAGRNativeDevMenuScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installNativeDevMenuHooks();
    });
}

__attribute__((constructor))
static void WAGRNativeDevMenuCtor(void) { /* launch-safe: install via WAGRNativeDevMenuEnsureHooksInstalled only */ }
