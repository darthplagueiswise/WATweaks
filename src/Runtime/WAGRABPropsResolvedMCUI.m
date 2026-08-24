#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>

#import "WAGRLog.h"

static UITableViewCell *(*orig_WAGRABResolvedMCCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL gWAGRABResolvedMCUIInstalled = NO;

static UITableViewCell *hook_WAGRABResolvedMCCell(id self,
                                                  SEL _cmd,
                                                  UITableView *tableView,
                                                  NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_WAGRABResolvedMCCell
        ? orig_WAGRABResolvedMCCell(self, _cmd, tableView, indexPath) : nil;
    if (!cell || !indexPath) return cell;

    NSArray *visible = nil;
    @try { visible = [self valueForKey:@"visibleEntries"]; }
    @catch (__unused NSException *exception) { visible = nil; }
    if ((NSUInteger)indexPath.row >= visible.count) return cell;

    NSDictionary *entry = [visible[(NSUInteger)indexPath.row] isKindOfClass:NSDictionary.class]
        ? visible[(NSUInteger)indexPath.row] : nil;
    NSDictionary *mc = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? entry[@"mobileconfig"] : nil;

    // The current exporter uses config_stable_id while older crosswalk files used
    // external_config_stable_id. The numeric value is the live result of
    // getStableIdFromParamSpecifier:; do not imply a second ID namespace here.
    id stableId = mc[@"config_stable_id"] ?: mc[@"external_config_stable_id"];
    if (!stableId) return cell;

    NSString *config = [mc[@"config_name"] isKindOfClass:NSString.class] ? mc[@"config_name"] : nil;
    NSString *parameter = [mc[@"parameter_name"] isKindOfClass:NSString.class] ? mc[@"parameter_name"] : nil;
    NSString *canonical = nil;
    if (config.length && parameter.length) canonical = [NSString stringWithFormat:@"%@.%@", config, parameter];
    else canonical = config.length ? config : parameter;

    NSString *resolved = canonical.length
        ? [NSString stringWithFormat:@"MC stable=%@ · p=%@ · %@",
           stableId, mc[@"parameter_index"] ?: @"?", canonical]
        : [NSString stringWithFormat:@"MC stable=%@ · p=%@",
           stableId, mc[@"parameter_index"] ?: @"?"];
    NSString *current = cell.detailTextLabel.text ?: @"";
    if (![current containsString:@"MC stable="]) {
        cell.detailTextLabel.text = current.length ? [current stringByAppendingFormat:@"\n%@", resolved] : resolved;
        cell.detailTextLabel.numberOfLines = 5;
    }
    return cell;
}

static void WAGRInstallABPropsResolvedMCUI(void) {
    if (gWAGRABResolvedMCUIInstalled) return;
    Class cls = NSClassFromString(@"WAGRABPropsSnapshotVC");
    if (!cls) return;
    SEL selector = @selector(tableView:cellForRowAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4) return;

    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *cursor = returnType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    if (*cursor != '@') return;

    IMP current = method_getImplementation(method);
    if (!current) return;
    orig_WAGRABResolvedMCCell = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))current;
    method_setImplementation(method, (IMP)hook_WAGRABResolvedMCCell);
    gWAGRABResolvedMCUIInstalled = method_getImplementation(method) == (IMP)hook_WAGRABResolvedMCCell;
    if (gWAGRABResolvedMCUIInstalled) {
        WAGRLogAppend(@"[ABProps][MCUI] stable-ID terminology installed");
    }
}

__attribute__((constructor))
static void WAGRABPropsResolvedMCUICtor(void) {
    @autoreleasepool {
        WAGRInstallABPropsResolvedMCUI();
    }
}
