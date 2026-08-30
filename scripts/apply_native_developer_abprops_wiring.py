#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "src/Hooks/WAGRNativeDevMenuHooks.xm"
VALIDATOR = ROOT / "scripts/wagr_validate_abprops_fetch.py"
MARKER = "watweaks_native_developer_abprops_wiring_v26_33"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def patch_hook() -> None:
    text = HOOK.read_text(encoding="utf-8")
    if MARKER in text:
        return

    text = text.replace('#import <mach-o/dyld.h>\n#import <mach-o/loader.h>\n', '')
    if '#import <objc/message.h>\n' not in text:
        text = replace_once(text, '#import <objc/runtime.h>\n', '#import <objc/runtime.h>\n#import <objc/message.h>\n', 'objc message import')

    text = replace_once(
        text,
        'static InitCtxIMP orig_privateExpInitWithUserContext = NULL;\ntypedef void (*VoidBoolIMP)(id, SEL, BOOL);\nstatic VoidBoolIMP orig_privateExpViewDidAppear = NULL;\n',
        'static InitCtxIMP orig_privateExpInitWithUserContext = NULL;\ntypedef void (*VoidIMP)(id, SEL);\nstatic VoidIMP orig_debugVCCreateSections = NULL;\n',
        'original IMP declarations')

    text = replace_once(
        text,
        'static BOOL gDebugVCHooked = NO;\nstatic BOOL gPrivateExpVCHooked = NO;\n',
        'static BOOL gDebugVCHooked = NO;\nstatic BOOL gPrivateExpVCHooked = NO;\nstatic BOOL gDebugABPropsSectionHooked = NO;\n',
        'hook state')

    stale = re.compile(
        r'// Current WhatsApp\(10\) build:.*?\nstatic BOOL WAGRGateForcedOn',
        re.S,
    )
    replacement = r'''// WhatsApp 26.33: the RC Developer controller compiles the yellow AB Props
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

static BOOL WAGRGateForcedOn'''
    text, count = stale.subn(replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"stale WhatsApp(10) dynamic-offset block: expected 1 match, found {count}")

    old_init = re.compile(
        r'static id hookPrivateExpInitWithUserContext\(id self, SEL _cmd, id ctx\) \{.*?\n\}\n\n\nstatic const char \*kWAGRPrivateExpVisibleKickDone.*?\nstatic void installUserContextCaptureHooks\(void\) \{.*?\n\}\n\n\n// ── WAContextMain / userContext spy',
        re.S,
    )
    new_init_and_install = r'''static id hookPrivateExpInitWithUserContext(id self, SEL _cmd, id ctx) {
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


// ── WAContextMain / userContext spy'''
    text, count = old_init.subn(new_init_and_install, text, count=1)
    if count != 1:
        raise SystemExit(f"PrivateExp old init/viewDidAppear/install block: expected 1 match, found {count}")

    forbidden = [
        "WAGRReadMainPointerAtVM",
        "WAGRPrivateExpKickManagerIfAvailable",
        "0x107d2f938",
        "0x107d2f940",
        "orig_privateExpViewDidAppear",
        "Current WhatsApp(10)",
    ]
    for token in forbidden:
        if token in text:
            raise SystemExit(f"old Developer/PrivateExp path still present: {token}")

    required = [
        MARKER,
        "hookDebugVCCreateSections",
        'NSSelectorFromString(@"createSections")',
        'WAGRNativeMethodEncodingMatches(dbg, createSel, "v16@0:8")',
        "Private Experimentation Debug",
        "privateABProperties",
        "addTableRowWithCellStyle:",
        "setRows:",
        "setFooterText:",
        "WAGRPrivateExperimentationRuntimeMetadata",
        'class_getInstanceVariable(cls, "experimentManager")',
        'class_getInstanceVariable(cls, "userContext")',
        "WAContextObjectProvider",
    ]
    for token in required:
        if token not in text:
            raise SystemExit(f"patched Developer hook missing invariant: {token}")

    HOOK.write_text(text, encoding="utf-8")


def patch_validator() -> None:
    text = VALIDATOR.read_text(encoding="utf-8")
    if 'DEV_MENU = ROOT / "src/Hooks/WAGRNativeDevMenuHooks.xm"' not in text:
        text = replace_once(
            text,
            'MC_EXPORT = ROOT / "src/Menu/WAGRMobileConfigExportVC.m"\n',
            'MC_EXPORT = ROOT / "src/Menu/WAGRMobileConfigExportVC.m"\nDEV_MENU = ROOT / "src/Hooks/WAGRNativeDevMenuHooks.xm"\n',
            'validator path')
    if 'dev_menu = read(DEV_MENU, errors)' not in text:
        text = replace_once(
            text,
            'mc_export = read(MC_EXPORT, errors)\n',
            'mc_export = read(MC_EXPORT, errors)\n    dev_menu = read(DEV_MENU, errors)\n',
            'validator read')

    if 'watweaks_native_developer_abprops_wiring_v26_33' not in text:
        anchor = '    timeout_section = live.split("explicit_transaction_timeout", 1)\n'
        checks = '''    # WhatsApp 26.33 RC compiles the yellow AB Props placeholder directly\n    # into WADebugViewController.createSections. The tweak must replace only\n    # that placeholder with a native WATableRow that pushes WhatsApp's own\n    # PrivateExperimentationDebugViewController using the account userContext.\n    for token in (\n        "watweaks_native_developer_abprops_wiring_v26_33",\n        "hookDebugVCCreateSections",\n        "createSections",\n        "v16@0:8",\n        "Private Experimentation Debug",\n        "privateABProperties",\n        "addTableRowWithCellStyle:",\n        "setRows:",\n        "setFooterText:",\n        "_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController",\n        'class_getInstanceVariable(cls, "experimentManager")',\n        'class_getInstanceVariable(cls, "userContext")',\n        "WAContextObjectProvider",\n    ):\n        require(dev_menu, token, "WAGRNativeDevMenuHooks.xm", errors)\n    for token in (\n        "WAGRReadMainPointerAtVM",\n        "WAGRPrivateExpKickManagerIfAvailable",\n        "0x107d2f938",\n        "0x107d2f940",\n        "orig_privateExpViewDidAppear",\n        "Current WhatsApp(10)",\n    ):\n        reject(dev_menu, token, "WAGRNativeDevMenuHooks.xm", errors)\n\n'''
        text = replace_once(text, anchor, checks + anchor, 'validator Developer checks')

    VALIDATOR.write_text(text, encoding="utf-8")


def main() -> int:
    patch_hook()
    patch_validator()
    print("native Developer AB Props wiring patch applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
