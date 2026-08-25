#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRRuntimeJSONEditor.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsCodeResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRSurface.h"

static UITableViewCell *(*gWAGRFinalABCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*gWAGRFinalABSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static UITableViewCell *(*gWAGRFinalSurfaceCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*gWAGRFinalSurfaceSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static id WAGRFinalKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRFinalEntryAt(id self, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (![self respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(self, selector, indexPath);
}

static NSString *WAGRFinalABCode(id self, WAGRABPropEntry *entry) {
    NSDictionary *index = WAGRFinalKVC(self, @"nativeEntriesBySelector");
    NSDictionary *native = [index[entry.selectorName] isKindOfClass:NSDictionary.class]
        ? index[entry.selectorName] : nil;
    NSString *nativeCode = [native[@"code"] description];
    if (nativeCode.length) return nativeCode;
    return WAGRABPropsCodeForEntry(entry);
}

static void WAGRFinalFitTitle(UITableViewCell *cell) {
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByClipping;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.48;
    cell.textLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
}

static id WAGRFinalABEffectiveValue(id self, WAGRABPropEntry *entry) {
    if (!entry) return nil;
    if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) {
        return WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod);
    }
    NSArray *runtimeObjects = WAGRFinalKVC(self, @"runtimeObjects") ?: @[];
    id raw = nil;
    (void)WAGRABPropsCurrentValue(entry, runtimeObjects, &raw);
    return raw;
}

static UITableViewCell *WAGRFinalABCellRenderer(id self, SEL _cmd,
                                                UITableView *table,
                                                NSIndexPath *indexPath) {
    UITableViewCell *cell = gWAGRFinalABCell
        ? gWAGRFinalABCell(self, _cmd, table, indexPath) : [UITableViewCell new];
    WAGRABPropEntry *entry = WAGRFinalEntryAt(self, indexPath);
    if (!entry) return cell;
    WAGRFinalFitTitle(cell);

    NSString *code = WAGRFinalABCode(self, entry);
    NSString *detail = cell.detailTextLabel.text ?: @"";
    if (code.length && [detail rangeOfString:[NSString stringWithFormat:@"AB %@", code]].location == NSNotFound) {
        detail = detail.length ? [detail stringByAppendingFormat:@" · AB %@", code]
                               : [NSString stringWithFormat:@"AB %@", code];
    }

    id effective = WAGRFinalABEffectiveValue(self, entry);
    if (WAGRRuntimeValueLooksLikeJSON(effective)) {
        NSString *typeName = WAGRRuntimeValueTypeName(entry.typeCode) ?: @"object";
        BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
        detail = [NSString stringWithFormat:@"JSON%@ · %@%@",
                  code.length ? [NSString stringWithFormat:@" · AB %@", code] : @"",
                  typeName, overridden ? @" · override" : @""];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    return cell;
}

static void WAGRFinalABDidSelect(id self, SEL _cmd,
                                 UITableView *table, NSIndexPath *indexPath) {
    WAGRABPropEntry *entry = WAGRFinalEntryAt(self, indexPath);
    id effective = WAGRFinalABEffectiveValue(self, entry);
    if (entry && WAGRRuntimeValueLooksLikeJSON(effective)) {
        [table deselectRowAtIndexPath:indexPath animated:YES];
        __weak id weakSelf = self;
        WAGRPresentRuntimeJSONEditor((UIViewController *)self,
            entry.selectorName, entry.className, entry.selectorName,
            entry.classMethod, entry.typeCode, effective, ^{
                id strongSelf = weakSelf;
                SEL apply = NSSelectorFromString(@"applyCurrentFilter");
                if (strongSelf && [strongSelf respondsToSelector:apply])
                    ((void (*)(id, SEL))objc_msgSend)(strongSelf, apply);
            });
        return;
    }
    if (gWAGRFinalABSelect) gWAGRFinalABSelect(self, _cmd, table, indexPath);
}

static id WAGRFinalSurfaceEffectiveValue(id self, WAGREntry *entry) {
    if (!entry) return nil;
    if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod)) {
        return WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.isClassMethod);
    }
    id raw = nil;
    SEL current = NSSelectorFromString(@"currentForEntry:raw:");
    if ([self respondsToSelector:current]) {
        ((id (*)(id, SEL, id, id *))objc_msgSend)(self, current, entry, &raw);
    }
    return raw;
}

static UITableViewCell *WAGRFinalSurfaceCellRenderer(id self, SEL _cmd,
                                                     UITableView *table,
                                                     NSIndexPath *indexPath) {
    UITableViewCell *cell = gWAGRFinalSurfaceCell
        ? gWAGRFinalSurfaceCell(self, _cmd, table, indexPath) : [UITableViewCell new];
    WAGREntry *entry = WAGRFinalEntryAt(self, indexPath);
    if (!entry) return cell;
    WAGRFinalFitTitle(cell);
    id effective = WAGRFinalSurfaceEffectiveValue(self, entry);
    if (WAGRRuntimeValueLooksLikeJSON(effective)) {
        BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · JSON · %@%@",
            entry.className ?: @"Runtime", entry.typeName ?: @"object",
            overridden ? @" · override" : @""];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRFinalSurfaceDidSelect(id self, SEL _cmd,
                                      UITableView *table, NSIndexPath *indexPath) {
    WAGREntry *entry = WAGRFinalEntryAt(self, indexPath);
    id effective = WAGRFinalSurfaceEffectiveValue(self, entry);
    if (entry && WAGRRuntimeValueLooksLikeJSON(effective)) {
        [table deselectRowAtIndexPath:indexPath animated:YES];
        __weak id weakSelf = self;
        WAGRPresentRuntimeJSONEditor((UIViewController *)self,
            entry.selectorName, entry.className, entry.selectorName,
            entry.isClassMethod, entry.typeCode, effective, ^{
                id strongSelf = weakSelf;
                SEL apply = NSSelectorFromString(@"applyCurrentFilter");
                if (strongSelf && [strongSelf respondsToSelector:apply])
                    ((void (*)(id, SEL))objc_msgSend)(strongSelf, apply);
            });
        return;
    }
    if (gWAGRFinalSurfaceSelect) gWAGRFinalSurfaceSelect(self, _cmd, table, indexPath);
}

static void WAGRFinalInstallForClass(Class cls,
                                     IMP cellReplacement,
                                     IMP selectReplacement,
                                     IMP *oldCell,
                                     IMP *oldSelect) {
    if (!cls) return;
    Method cell = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    Method select = class_getInstanceMethod(cls, @selector(tableView:didSelectRowAtIndexPath:));
    if (cell && method_getImplementation(cell) != cellReplacement) {
        *oldCell = method_getImplementation(cell);
        method_setImplementation(cell, cellReplacement);
    }
    if (select && method_getImplementation(select) != selectReplacement) {
        *oldSelect = method_getImplementation(select);
        method_setImplementation(select, selectReplacement);
    }
}

static void WAGRFinalConsistencyInstall(void) {
    WAGRFinalInstallForClass(NSClassFromString(@"WAGRABPropsBrowserVC"),
        (IMP)WAGRFinalABCellRenderer, (IMP)WAGRFinalABDidSelect,
        (IMP *)&gWAGRFinalABCell, (IMP *)&gWAGRFinalABSelect);
    WAGRFinalInstallForClass(NSClassFromString(@"WAGRSurfaceBrowserVC"),
        (IMP)WAGRFinalSurfaceCellRenderer, (IMP)WAGRFinalSurfaceDidSelect,
        (IMP *)&gWAGRFinalSurfaceCell, (IMP *)&gWAGRFinalSurfaceSelect);
}

__attribute__((constructor))
static void WAGRFinalConsistencyCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRFinalConsistencyInstall(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WAGRFinalConsistencyInstall(); });
        });
    }
}
