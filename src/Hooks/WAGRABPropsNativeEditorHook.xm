#import <UIKit/UIKit.h>
#import "../Menu/WAGRABPropsBrowserVC.h"
#import "../Menu/WAGRABPropsNativeEditor.h"
#import "../Menu/WAGRRuntimeValueEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"

static NSString *WAGRABStableIDHintForBrowserEntry(id browser, WAGRABPropEntry *entry) {
    if (!entry) return nil;
    NSString *resolved = WAGRABPropsStableIDForTarget(entry.className,
                                                       entry.selectorName,
                                                       entry.classMethod);
    if (resolved.length) return resolved;

    // Secondary runtime/cache correlation only. This is not a fabricated ID:
    // nativeEntriesBySelector is built from the account's gabp snapshot plus the
    // current runtime correlation in WAGRABPropsBrowserVC.
    @try {
        NSDictionary *index = [browser valueForKey:@"nativeEntriesBySelector"];
        NSDictionary *native = [index[entry.selectorName] isKindOfClass:NSDictionary.class]
            ? index[entry.selectorName] : nil;
        id code = native[@"code"];
        NSString *candidate = nil;
        if ([code isKindOfClass:NSString.class]) candidate = code;
        else if ([code isKindOfClass:NSNumber.class]) candidate = [(NSNumber *)code stringValue];
        if (candidate.length) {
            NSCharacterSet *bad = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
            if ([candidate rangeOfCharacterFromSet:bad].location == NSNotFound) return candidate;
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

%hook WAGRABPropsBrowserVC

- (void)viewDidLoad {
    %orig;
    // "Overrides" used to mean RuntimeValueStore/swizzle state. That is no
    // longer the primary ABProps persistence model, so do not expose a filter
    // whose semantics are now false. Native override state is shown in-editor.
    @try {
        UISearchController *search = [self valueForKey:@"searchController"];
        if ([search isKindOfClass:UISearchController.class]) {
            search.searchBar.scopeButtonTitles = @[ @"Todos", @"BOOL", @"Números", @"Objetos" ];
            if (search.searchBar.selectedScopeButtonIndex > 3) {
                search.searchBar.selectedScopeButtonIndex = 0;
            }
        }
    } @catch (__unused NSException *exception) {}
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    // BOOL used to expose an inline UISwitch wired directly to
    // WAGRRuntimeValueSetOverride/MSHookMessageEx. Remove that write surface:
    // tapping the row now opens the native UserSession MobileConfig editor.
    if ([cell.accessoryView isKindOfClass:UISwitch.class]) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)presentEditorForEntry:(WAGRABPropEntry *)entry fromView:(UIView *)sourceView {
    if (!entry) return;

    NSArray *runtimeObjects = @[];
    id userContext = nil;
    @try {
        id objects = [self valueForKey:@"runtimeObjects"];
        if ([objects isKindOfClass:NSArray.class]) runtimeObjects = objects;
        userContext = [self valueForKey:@"userContext"];
    } @catch (__unused NSException *exception) {}

    NSString *stableID = WAGRABStableIDHintForBrowserEntry(self, entry);
    __weak WAGRABPropsBrowserVC *weakSelf = self;
    __weak UIView *weakSource = sourceView;
    dispatch_block_t runtimeFallback = ^{
        WAGRABPropsBrowserVC *strongSelf = weakSelf;
        if (!strongSelf) return;
        id raw = nil;
        NSString *current = WAGRABPropsCurrentValue(entry, runtimeObjects, &raw);
        WAGRPresentRuntimeValueEditor(strongSelf, weakSource,
            entry.className, entry.selectorName, entry.classMethod, entry.typeCode,
            current, raw, ^{
                if ([strongSelf respondsToSelector:@selector(scanNow)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [strongSelf performSelector:@selector(scanNow)];
#pragma clang diagnostic pop
                }
            });
    };

    WAGRPresentABPropsNativeEditor(self, sourceView, entry, runtimeObjects,
                                   userContext, stableID, runtimeFallback, ^{
        WAGRABPropsBrowserVC *strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf respondsToSelector:@selector(scanNow)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [strongSelf performSelector:@selector(scanNow)];
#pragma clang diagnostic pop
        }
    });
}

%end
