#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsABTNativeBridge.h"
#import "../Runtime/WAGRUserContextLinkage.h"
#import "../Runtime/WAGRLog.h"

// Replaces the historical "send request, then poll gabp fingerprint to infer
// success" UI path. The request is still sent through WhatsApp's exact native
// manager, but UI completion now comes from the decoded native response handler;
// persisted gabp state is only a post-handler WAPropertiesStore confirmation.

static void (*gWAGRABTOriginalBrowserFetch)(id, SEL) = NULL;
static id (*gWAGRABTOriginalDebugBuild)(id, SEL, BOOL) = NULL;
static void (*gWAGRABTOriginalDebugFetch)(id, SEL) = NULL;
static id (*gWAGRABTOriginalDebugCell)(id, SEL, id, id) = NULL;
static BOOL gWAGRABTBrowserUIInstalled = NO;
static BOOL gWAGRABTDebugUIInstalled = NO;

static id WAGRABTUIKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRABTUISetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void WAGRABTUIShowAlert(id controller, NSString *title, NSString *message) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"ABProps"
        message:message ?: @""
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)controller presentViewController:alert animated:YES completion:nil];
}

static NSString *WAGRABTUIResultSummary(NSDictionary *result) {
    NSDictionary *didSucceed = [result[@"did_succeed_response"] isKindOfClass:NSDictionary.class]
        ? result[@"did_succeed_response"] : @{};
    NSDictionary *decoded = [result[@"decoded_response"] isKindOfClass:NSDictionary.class]
        ? result[@"decoded_response"] : @{};
    NSDictionary *store = [result[@"wa_properties_store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"wa_properties_store_confirmation"] : @{};

    BOOL sawDidSucceed = didSucceed.count > 0;
    BOOL sawHandler = decoded.count > 0;
    BOOL storeChecked = [store[@"checked_after_native_handler"] boolValue];
    BOOL storeAvailable = [store[@"cache_available"] boolValue];
    BOOL fingerprintChanged = [store[@"fingerprint_changed"] boolValue];
    BOOL metadataMatches = [store[@"response_metadata_matches_persisted"] boolValue];
    BOOL delta = [decoded[@"delta_update"] boolValue];
    NSUInteger props = [decoded[@"prop_count"] unsignedIntegerValue];
    NSUInteger sampling = [decoded[@"sampling_count"] unsignedIntegerValue];
    id error = decoded[@"error"];
    BOOL hasError = error && error != NSNull.null && !([error isKindOfClass:NSString.class] && [error isEqualToString:@"nil"]);

    if (!sawHandler) {
        return [NSString stringWithFormat:@"ABT enviado · didSucceed=%@ · handler decodificado não observado%@",
            sawDidSucceed ? @"YES" : @"NO", hasError ? @" · erro" : @""];
    }
    return [NSString stringWithFormat:
        @"ABT %@ · didSucceed=%@ · handler=YES · props=%lu · sampling=%lu · store=%@ · metadata=%@ · gabpΔ=%@%@",
        delta ? @"delta" : @"full",
        sawDidSucceed ? @"YES" : @"NO",
        (unsigned long)props,
        (unsigned long)sampling,
        (storeChecked && storeAvailable) ? @"OK" : @"não confirmado",
        metadataMatches ? @"MATCH" : @"sem match",
        fingerprintChanged ? @"YES" : @"NO",
        hasError ? @" · handler error" : @""];
}

static void WAGRABTBrowserFetch(id self, SEL _cmd) {
    (void)_cmd;
    if ([WAGRABTUIKVC(self, @"fetching") boolValue]) return;
    WAGRABTUISetKVC(self, @"fetching", @YES);
    UIBarButtonItem *button = WAGRABTUIKVC(self, @"fetchButton");
    if ([button isKindOfClass:UIBarButtonItem.class]) button.enabled = NO;
    if ([self isKindOfClass:UIViewController.class]) ((UIViewController *)self).title = @"ABT: enviando…";

    id context = WAGRABTUIKVC(self, @"userContext") ?: WAGRCurrentUserContext();
    __weak id weakSelf = self;
    NSString *diagnostic = nil;
    BOOL invoked = WAGRABPropsABTTriggerFetch(context, NO, ^(NSDictionary<NSString *,id> *result) {
        id browser = weakSelf;
        if (!browser) return;
        NSString *summary = WAGRABTUIResultSummary(result);
        WAGRABTUISetKVC(browser, @"fetching", @NO);
        UIBarButtonItem *fetchButton = WAGRABTUIKVC(browser, @"fetchButton");
        if ([fetchButton isKindOfClass:UIBarButtonItem.class]) fetchButton.enabled = YES;
        WAGRABTUISetKVC(browser, @"lastFetchNote", summary);
        WAGRLogAppendF(@"[ABProps][ABT][Browser] %@", summary);

        SEL scan = NSSelectorFromString(@"scanNow");
        if ([browser respondsToSelector:scan]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(browser, scan); }
            @catch (__unused NSException *exception) {}
        }
    }, &diagnostic);

    if (!invoked) {
        WAGRABTUISetKVC(self, @"fetching", @NO);
        if ([button isKindOfClass:UIBarButtonItem.class]) button.enabled = YES;
        WAGRABTUISetKVC(self, @"lastFetchNote", diagnostic ?: @"ABT nativo não enviado.");
        WAGRABTUIShowAlert(self, @"ABProps ABT", diagnostic ?: @"ABT nativo não enviado.");
    } else {
        WAGRABTUISetKVC(self, @"lastFetchNote", diagnostic ?: @"ABT enviado; aguardando handler nativo decodificado…");
    }
}

static void WAGRABTDebugSetWorking(id controller, NSString *status, BOOL working) {
    SEL selector = NSSelectorFromString(@"setWorkingStatus:working:");
    if (![controller respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, selector, status ?: @"", working); }
    @catch (__unused NSException *exception) {}
}

static void WAGRABTDebugFetch(id self, SEL _cmd) {
    (void)_cmd;
    if ([WAGRABTUIKVC(self, @"working") boolValue]) return;
    id context = WAGRCurrentUserContext();
    __weak id weakSelf = self;
    NSString *diagnostic = nil;
    BOOL invoked = WAGRABPropsABTTriggerFetch(context, NO, ^(NSDictionary<NSString *,id> *result) {
        id controller = weakSelf;
        if (!controller) return;
        NSString *summary = WAGRABTUIResultSummary(result);
        WAGRABTDebugSetWorking(controller, summary, NO);
        WAGRLogAppendF(@"[ABProps][ABT][Debug] %@", summary);
    }, &diagnostic);

    if (!invoked) {
        SEL alert = NSSelectorFromString(@"showSimpleAlert:message:");
        if ([self respondsToSelector:alert]) {
            @try { ((void (*)(id, SEL, id, id))objc_msgSend)(self, alert, @"ABProps ABT", diagnostic ?: @"ABT nativo não enviado."); }
            @catch (__unused NSException *exception) {}
        } else {
            WAGRABTUIShowAlert(self, @"ABProps ABT", diagnostic ?: @"ABT nativo não enviado.");
        }
        return;
    }
    WAGRABTDebugSetWorking(self,
        diagnostic ?: @"ABT enviado; aguardando didSucceed → handler decodificado → WAPropertiesStore…",
        YES);
}

static id WAGRABTDebugBuild(id self, SEL _cmd, BOOL deep) {
    id original = gWAGRABTOriginalDebugBuild ? gWAGRABTOriginalDebugBuild(self, _cmd, deep) : nil;
    NSMutableDictionary *document = [original isKindOfClass:NSDictionary.class]
        ? [(NSDictionary *)original mutableCopy] : [NSMutableDictionary dictionary];
    document[@"schema"] = @"watweaks_debug_runtime_v3";
    document[@"abprops_abt_native_bridge"] = WAGRABPropsABTNativeBridgeDocument() ?: @{};
    return document;
}

static id WAGRABTDebugCell(id self, SEL _cmd, id tableView, id indexPathObject) {
    id cell = gWAGRABTOriginalDebugCell
        ? gWAGRABTOriginalDebugCell(self, _cmd, tableView, indexPathObject) : nil;
    NSIndexPath *indexPath = [indexPathObject isKindOfClass:NSIndexPath.class] ? indexPathObject : nil;
    if (indexPath.section == 0 && indexPath.row == 2 && [cell isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *typed = cell;
        typed.textLabel.text = @"Fetch ABProps ABT nativo";
        typed.detailTextLabel.text = @"requestFreshABProps (regular/hash) → didSucceedWithResponse → handler decodificado → confirmação WAPropertiesStore; sem inferir rede pelo fingerprint.";
    }
    return cell;
}

static BOOL WAGRABTInstallBrowserUI(void) {
    if (gWAGRABTBrowserUIInstalled) return YES;
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"fetchNow")) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)WAGRABTBrowserFetch) {
        gWAGRABTOriginalBrowserFetch = (void (*)(id, SEL))current;
        method_setImplementation(method, (IMP)WAGRABTBrowserFetch);
    }
    gWAGRABTBrowserUIInstalled = YES;
    return YES;
}

static BOOL WAGRABTInstallDebugUI(void) {
    if (gWAGRABTDebugUIInstalled) return YES;
    Class cls = NSClassFromString(@"WAGRDebugDiagnosticsVC");
    if (!cls) return NO;

    Method build = class_getInstanceMethod(cls, NSSelectorFromString(@"buildDiagnosticDocumentDeep:"));
    Method fetch = class_getInstanceMethod(cls, NSSelectorFromString(@"fetchABProps"));
    Method cell = class_getInstanceMethod(cls, NSSelectorFromString(@"tableView:cellForRowAtIndexPath:"));
    if (!build || !fetch || !cell) return NO;

    IMP buildCurrent = method_getImplementation(build);
    IMP fetchCurrent = method_getImplementation(fetch);
    IMP cellCurrent = method_getImplementation(cell);
    if (!buildCurrent || !fetchCurrent || !cellCurrent) return NO;

    if (buildCurrent != (IMP)WAGRABTDebugBuild) {
        gWAGRABTOriginalDebugBuild = (id (*)(id, SEL, BOOL))buildCurrent;
        method_setImplementation(build, (IMP)WAGRABTDebugBuild);
    }
    if (fetchCurrent != (IMP)WAGRABTDebugFetch) {
        gWAGRABTOriginalDebugFetch = (void (*)(id, SEL))fetchCurrent;
        method_setImplementation(fetch, (IMP)WAGRABTDebugFetch);
    }
    if (cellCurrent != (IMP)WAGRABTDebugCell) {
        gWAGRABTOriginalDebugCell = (id (*)(id, SEL, id, id))cellCurrent;
        method_setImplementation(cell, (IMP)WAGRABTDebugCell);
    }
    gWAGRABTDebugUIInstalled = YES;
    return YES;
}

static void WAGRABTInstallUI(void) {
    BOOL browser = WAGRABTInstallBrowserUI();
    BOOL debug = WAGRABTInstallDebugUI();
    if (browser || debug) {
        WAGRLogAppendF(@"[ABProps][ABT][UI] browser=%@ debug=%@",
                       browser ? @"YES" : @"NO", debug ? @"YES" : @"NO");
    }
}

__attribute__((constructor))
static void WAGRABPropsABTNativeBridgeUICtor(void) {
    @autoreleasepool {
        WAGRABTInstallUI();
        for (NSNumber *delay in @[@0.35, @0.90, @1.80, @3.20]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                           (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRABTInstallUI(); });
        }
    }
}
