#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsABTLiveService.h"
#import "../Runtime/WAGRABPropsABTNativeBridge.h"
#import "../Runtime/WAGRUserContextLinkage.h"
#import "../Runtime/WAGRLog.h"

static void (*gBrowserOriginalFetch)(id, SEL) = NULL;
static void (*gDebugOriginalFetch)(id, SEL) = NULL;
static id (*gDebugOriginalBuild)(id, SEL, BOOL) = NULL;
static id (*gDebugOriginalCell)(id, SEL, id, id) = NULL;
static BOOL gBrowserInstalled = NO;
static BOOL gDebugInstalled = NO;

static id KVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *exception) { return nil; }
}

static void SetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; } @catch (__unused NSException *exception) {}
}

static NSString *Summary(NSDictionary *result) {
    NSString *outcome = [result[@"outcome"] isKindOfClass:NSString.class] ? result[@"outcome"] : @"?";
    NSUInteger wire = [result[@"wire_prop_count"] unsignedIntegerValue];
    NSUInteger effective = [result[@"effective_prop_count"] unsignedIntegerValue];
    NSDictionary *decoded = [result[@"decoded_response"] isKindOfClass:NSDictionary.class] ? result[@"decoded_response"] : @{};
    NSDictionary *store = [result[@"store_confirmation"] isKindOfClass:NSDictionary.class] ? result[@"store_confirmation"] : @{};
    BOOL delta = [decoded[@"delta_update"] boolValue];
    BOOL lower = [result[@"lower_request_entered"] boolValue];
    BOOL metadata = [store[@"metadata_matches"] boolValue];
    BOOL changed = [store[@"fingerprint_changed"] boolValue];
    NSString *source = [result[@"effective_source"] isKindOfClass:NSString.class] ? result[@"effective_source"] : @"?";
    return [NSString stringWithFormat:
        @"ABT %@ · lower=%@ · wire=%lu · effective=%lu · storeMeta=%@ · gabpΔ=%@ · %@ · %@",
        delta ? @"delta" : @"full",
        lower ? @"YES" : @"NO",
        (unsigned long)wire,
        (unsigned long)effective,
        metadata ? @"MATCH" : @"NO",
        changed ? @"YES" : @"NO",
        outcome,
        source];
}

static void ShowAlert(id controller, NSString *message) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ABProps ABT Live"
        message:message ?: @""
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)controller presentViewController:alert animated:YES completion:nil];
}

static void DebugSetWorking(id controller, NSString *status, BOOL working) {
    SEL selector = NSSelectorFromString(@"setWorkingStatus:working:");
    if (![controller respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, selector, status ?: @"", working); }
    @catch (__unused NSException *exception) {}
}

static void RefreshDebugDocumentWithLiveResult(id controller, NSDictionary *result) {
    NSMutableDictionary *document = [[KVC(controller, @"document") isKindOfClass:NSDictionary.class]
        ? KVC(controller, @"document") : @{} mutableCopy];
    if (!document) document = [NSMutableDictionary dictionary];
    document[@"schema"] = @"watweaks_debug_runtime_v4";
    document[@"abprops_abt_live_service"] = result ?: @{};
    document[@"abprops_abt_native_bridge"] = WAGRABPropsABTNativeBridgeDocument() ?: @{};
    SetKVC(controller, @"document", document);
    UITableView *table = KVC(controller, @"tableView");
    [table reloadData];
}

static void DebugFetch(id self, SEL _cmd) {
    (void)_cmd;
    if ([KVC(self, @"working") boolValue]) return;
    NSString *diagnostic = nil;
    __weak id weakSelf = self;
    BOOL sent = WAGRABPropsABTLiveFetch(WAGRCurrentUserContext(), ^(NSDictionary<NSString *,id> *result) {
        id controller = weakSelf;
        if (!controller) return;
        RefreshDebugDocumentWithLiveResult(controller, result);
        NSString *summary = Summary(result);
        DebugSetWorking(controller, summary, NO);
        WAGRLogAppendF(@"[ABProps][ABTLive][Debug] %@", summary);
    }, &diagnostic);
    if (!sent) {
        ShowAlert(self, diagnostic ?: @"ABT live request not sent.");
        return;
    }
    DebugSetWorking(self,
        diagnostic ?: @"ABT explicit request entered native lower pipeline; awaiting exact native completion…",
        YES);
}

static void BrowserFetch(id self, SEL _cmd) {
    (void)_cmd;
    if ([KVC(self, @"fetching") boolValue]) return;
    SetKVC(self, @"fetching", @YES);
    UIBarButtonItem *button = KVC(self, @"fetchButton");
    if ([button isKindOfClass:UIBarButtonItem.class]) button.enabled = NO;
    id context = KVC(self, @"userContext") ?: WAGRCurrentUserContext();
    __weak id weakSelf = self;
    NSString *diagnostic = nil;
    BOOL sent = WAGRABPropsABTLiveFetch(context, ^(NSDictionary<NSString *,id> *result) {
        id browser = weakSelf;
        if (!browser) return;
        NSString *summary = Summary(result);
        SetKVC(browser, @"fetching", @NO);
        SetKVC(browser, @"lastFetchNote", summary);
        UIBarButtonItem *fetchButton = KVC(browser, @"fetchButton");
        if ([fetchButton isKindOfClass:UIBarButtonItem.class]) fetchButton.enabled = YES;
        SEL scan = NSSelectorFromString(@"scanNow");
        if ([browser respondsToSelector:scan]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(browser, scan); }
            @catch (__unused NSException *exception) {}
        }
        WAGRLogAppendF(@"[ABProps][ABTLive][Browser] %@", summary);
    }, &diagnostic);
    if (!sent) {
        SetKVC(self, @"fetching", @NO);
        if ([button isKindOfClass:UIBarButtonItem.class]) button.enabled = YES;
        SetKVC(self, @"lastFetchNote", diagnostic ?: @"ABT live request not sent.");
        ShowAlert(self, diagnostic ?: @"ABT live request not sent.");
    } else {
        SetKVC(self, @"lastFetchNote", diagnostic ?: @"ABT explicit request correlated; awaiting native completion…");
    }
}

static id DebugBuild(id self, SEL _cmd, BOOL deep) {
    id base = gDebugOriginalBuild ? gDebugOriginalBuild(self, _cmd, deep) : nil;
    NSMutableDictionary *document = [base isKindOfClass:NSDictionary.class]
        ? [(NSDictionary *)base mutableCopy] : [NSMutableDictionary dictionary];
    document[@"schema"] = @"watweaks_debug_runtime_v4";
    document[@"abprops_abt_live_service"] = WAGRABPropsABTLiveServiceDocument() ?: @{};
    document[@"abprops_abt_native_bridge"] = WAGRABPropsABTNativeBridgeDocument() ?: @{};
    return document;
}

static id DebugCell(id self, SEL _cmd, id tableView, id indexPathObject) {
    id cell = gDebugOriginalCell ? gDebugOriginalCell(self, _cmd, tableView, indexPathObject) : nil;
    NSIndexPath *indexPath = [indexPathObject isKindOfClass:NSIndexPath.class] ? indexPathObject : nil;
    if (indexPath.section == 0 && indexPath.row == 2 && [cell isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *typed = cell;
        typed.textLabel.text = @"Fetch ABProps ABT Live";
        typed.detailTextLabel.text = @"Correlaciona requestFreshABProps → método nativo inferior → didSucceed/handler → completion exato. wire=0 é no-change; o resultado efetivo vem do WAPropertiesStore pós-resposta.";
    }
    return cell;
}

static BOOL InstallBrowser(void) {
    if (gBrowserInstalled) return YES;
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"fetchNow")) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current != (IMP)BrowserFetch) {
        gBrowserOriginalFetch = (void (*)(id, SEL))current;
        method_setImplementation(method, (IMP)BrowserFetch);
    }
    gBrowserInstalled = YES;
    return YES;
}

static BOOL InstallDebug(void) {
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
    if (fetchCurrent != (IMP)DebugFetch) {
        gDebugOriginalFetch = (void (*)(id, SEL))fetchCurrent;
        method_setImplementation(fetch, (IMP)DebugFetch);
    }
    if (buildCurrent != (IMP)DebugBuild) {
        gDebugOriginalBuild = (id (*)(id, SEL, BOOL))buildCurrent;
        method_setImplementation(build, (IMP)DebugBuild);
    }
    if (cellCurrent != (IMP)DebugCell) {
        gDebugOriginalCell = (id (*)(id, SEL, id, id))cellCurrent;
        method_setImplementation(cell, (IMP)DebugCell);
    }
    gDebugInstalled = YES;
    return YES;
}

static void InstallUI(void) {
    BOOL browser = InstallBrowser();
    BOOL debug = InstallDebug();
    if (browser || debug) WAGRLogAppendF(@"[ABProps][ABTLive][UI] browser=%@ debug=%@",
                                         browser ? @"YES" : @"NO",
                                         debug ? @"YES" : @"NO");
}

__attribute__((constructor))
static void WAGRABPropsABTLiveServiceUICtor(void) {
    @autoreleasepool {
        // Existing ABT UI wrapper retries through +3.2 s. Install outside that
        // window so the correlated service remains the final fetch implementation.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ InstallUI(); });
    }
}
