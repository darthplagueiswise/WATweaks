#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsABTForceFull.h"
#import "../Runtime/WAGRABPropsABTLiveService.h"
#import "../Runtime/WAGRUserContextLinkage.h"
#import "../Runtime/WAGRLog.h"

static void (*gPriorBrowserFetch)(id, SEL) = NULL;
static void (*gPriorDebugFetch)(id, SEL) = NULL;
static id (*gPriorDebugBuild)(id, SEL, BOOL) = NULL;
static id (*gPriorDebugCell)(id, SEL, id, id) = NULL;
static BOOL gBrowserInstalled = NO;
static BOOL gDebugInstalled = NO;

static id SafeKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void SafeSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void ShowAlert(id controller, NSString *message) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ABProps ABT Force Full"
        message:message ?: @""
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)controller presentViewController:alert animated:YES completion:nil];
}

static void SetDebugWorking(id controller, NSString *status, BOOL working) {
    SEL selector = NSSelectorFromString(@"setWorkingStatus:working:");
    if (![controller respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, selector, status ?: @"", working); }
    @catch (__unused NSException *exception) {}
}

static NSString *ForcedSummary(NSDictionary *result) {
    NSUInteger wire = [result[@"wire_prop_count"] unsignedIntegerValue];
    NSUInteger effective = [result[@"effective_prop_count"] unsignedIntegerValue];
    NSDictionary *force = [result[@"forced_full_request"] isKindOfClass:NSDictionary.class]
        ? result[@"forced_full_request"] : @{};
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class]
        ? result[@"store_confirmation"] : @{};
    BOOL applied = [force[@"applied"] boolValue];
    BOOL lower = [result[@"lower_request_entered"] boolValue];
    BOOL metadata = [store[@"metadata_matches"] boolValue];
    NSString *outcome = [result[@"outcome"] isKindOfClass:NSString.class] ? result[@"outcome"] : @"?";
    return [NSString stringWithFormat:
        @"ABT force-full · validators=%@ · lower=%@ · wire=%lu · effective=%lu · storeMeta=%@ · %@",
        applied ? @"STRIPPED" : @"NOT_APPLIED",
        lower ? @"YES" : @"NO",
        (unsigned long)wire,
        (unsigned long)effective,
        metadata ? @"MATCH" : @"NO",
        outcome];
}

static void RefreshDebugDocument(id controller, NSDictionary *result) {
    NSDictionary *existing = [SafeKVC(controller, @"document") isKindOfClass:NSDictionary.class]
        ? SafeKVC(controller, @"document") : @{};
    NSMutableDictionary *document = [existing mutableCopy] ?: [NSMutableDictionary dictionary];
    document[@"schema"] = @"watweaks_debug_runtime_v5";
    document[@"abprops_abt_live_service"] = result ?: @{};
    document[@"abprops_abt_force_full"] = WAGRABPropsABTForceFullDocument() ?: @{};
    SafeSetKVC(controller, @"document", document);
    UITableView *table = SafeKVC(controller, @"tableView");
    [table reloadData];
}

static void ForcedDebugFetch(id self, SEL _cmd) {
    (void)_cmd;
    if ([SafeKVC(self, @"working") boolValue]) return;

    NSString *diagnostic = nil;
    __weak id weakSelf = self;
    BOOL sent = WAGRABPropsABTLiveFetchForcedFull(WAGRCurrentUserContext(), ^(NSDictionary<NSString *,id> *result) {
        id controller = weakSelf;
        if (!controller) return;
        RefreshDebugDocument(controller, result);
        NSString *summary = ForcedSummary(result);
        SetDebugWorking(controller, summary, NO);
        WAGRLogAppendF(@"[ABProps][ABTForceFull][Debug] %@", summary);
    }, &diagnostic);

    if (!sent) {
        ShowAlert(self, diagnostic ?: @"Forced-full ABT request not sent.");
        return;
    }
    SetDebugWorking(self,
        diagnostic ?: @"ABT force-full enviado; aguardando request constructor, resposta, handler e store…",
        YES);
}

static void ForcedBrowserFetch(id self, SEL _cmd) {
    (void)_cmd;
    if ([SafeKVC(self, @"fetching") boolValue]) return;
    SafeSetKVC(self, @"fetching", @YES);
    UIBarButtonItem *button = SafeKVC(self, @"fetchButton");
    if ([button isKindOfClass:UIBarButtonItem.class]) button.enabled = NO;

    id context = SafeKVC(self, @"userContext") ?: WAGRCurrentUserContext();
    NSString *diagnostic = nil;
    __weak id weakSelf = self;
    BOOL sent = WAGRABPropsABTLiveFetchForcedFull(context, ^(NSDictionary<NSString *,id> *result) {
        id browser = weakSelf;
        if (!browser) return;
        NSString *summary = ForcedSummary(result);
        SafeSetKVC(browser, @"fetching", @NO);
        SafeSetKVC(browser, @"lastFetchNote", summary);
        UIBarButtonItem *fetchButton = SafeKVC(browser, @"fetchButton");
        if ([fetchButton isKindOfClass:UIBarButtonItem.class]) fetchButton.enabled = YES;
        SEL scan = NSSelectorFromString(@"scanNow");
        if ([browser respondsToSelector:scan]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(browser, scan); }
            @catch (__unused NSException *exception) {}
        }
        WAGRLogAppendF(@"[ABProps][ABTForceFull][Browser] %@", summary);
    }, &diagnostic);

    if (!sent) {
        SafeSetKVC(self, @"fetching", @NO);
        if ([button isKindOfClass:UIBarButtonItem.class]) button.enabled = YES;
        SafeSetKVC(self, @"lastFetchNote", diagnostic ?: @"Forced-full ABT request not sent.");
        ShowAlert(self, diagnostic ?: @"Forced-full ABT request not sent.");
        return;
    }
    SafeSetKVC(self, @"lastFetchNote", diagnostic ?: @"ABT force-full armed; awaiting exact native completion…");
}

static id ForcedDebugBuild(id self, SEL _cmd, BOOL deep) {
    id base = gPriorDebugBuild ? gPriorDebugBuild(self, _cmd, deep) : nil;
    NSMutableDictionary *document = [base isKindOfClass:NSDictionary.class]
        ? [(NSDictionary *)base mutableCopy] : [NSMutableDictionary dictionary];
    document[@"schema"] = @"watweaks_debug_runtime_v5";
    document[@"abprops_abt_force_full"] = WAGRABPropsABTForceFullDocument() ?: @{};
    return document;
}

static id ForcedDebugCell(id self, SEL _cmd, id tableView, id indexPathObject) {
    id cell = gPriorDebugCell ? gPriorDebugCell(self, _cmd, tableView, indexPathObject) : nil;
    NSIndexPath *indexPath = [indexPathObject isKindOfClass:NSIndexPath.class] ? indexPathObject : nil;
    if (indexPath.section == 0 && indexPath.row == 2 && [cell isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *typed = cell;
        typed.textLabel.text = @"Fetch ABProps ABT Full";
        typed.detailTextLabel.text = @"Usa o pipeline ABT nativo, mas remove configHash e refreshID no init de XMPPRequestABProperties. Assim o servidor não pode responder apenas ‘no-change’ por esses validators; o relatório separa wire props do WAPropertiesStore efetivo.";
    }
    return cell;
}

static BOOL InstallBrowserOverride(void) {
    if (gBrowserInstalled) return YES;
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"fetchNow")) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)ForcedBrowserFetch) {
        gPriorBrowserFetch = (void (*)(id, SEL))current;
        method_setImplementation(method, (IMP)ForcedBrowserFetch);
    }
    gBrowserInstalled = YES;
    return YES;
}

static BOOL InstallDebugOverride(void) {
    if (gDebugInstalled) return YES;
    Class cls = NSClassFromString(@"WAGRDebugDiagnosticsVC");
    if (!cls) return NO;
    Method fetch = class_getInstanceMethod(cls, NSSelectorFromString(@"fetchABProps"));
    Method build = class_getInstanceMethod(cls, NSSelectorFromString(@"buildDiagnosticDocumentDeep:"));
    Method cell = class_getInstanceMethod(cls, NSSelectorFromString(@"tableView:cellForRowAtIndexPath:"));
    if (!fetch || !build || !cell) return NO;

    IMP fetchCurrent = method_getImplementation(fetch);
    IMP buildCurrent = method_getImplementation(build);
    IMP cellCurrent = method_getImplementation(cell);
    if (!fetchCurrent || !buildCurrent || !cellCurrent) return NO;

    if (fetchCurrent != (IMP)ForcedDebugFetch) {
        gPriorDebugFetch = (void (*)(id, SEL))fetchCurrent;
        method_setImplementation(fetch, (IMP)ForcedDebugFetch);
    }
    if (buildCurrent != (IMP)ForcedDebugBuild) {
        gPriorDebugBuild = (id (*)(id, SEL, BOOL))buildCurrent;
        method_setImplementation(build, (IMP)ForcedDebugBuild);
    }
    if (cellCurrent != (IMP)ForcedDebugCell) {
        gPriorDebugCell = (id (*)(id, SEL, id, id))cellCurrent;
        method_setImplementation(cell, (IMP)ForcedDebugCell);
    }
    gDebugInstalled = YES;
    return YES;
}

static void InstallForcedFullUI(void) {
    BOOL browser = InstallBrowserOverride();
    BOOL debug = InstallDebugOverride();
    if (browser || debug) {
        WAGRLogAppendF(@"[ABProps][ABTForceFull][UI] browser=%@ debug=%@",
                       browser ? @"YES" : @"NO", debug ? @"YES" : @"NO");
    }
}

__attribute__((constructor))
static void WAGRABPropsABTForceFullUICtor(void) {
    @autoreleasepool {
        // WAGRABPropsABTLiveServiceUI installs at +4.8 s. Install after it so
        // this remains the final fetch surface while keeping the same UI shell.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ InstallForcedFullUI(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ InstallForcedFullUI(); });
    }
}
