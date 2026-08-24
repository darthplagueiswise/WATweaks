#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

static const void *kWAGRCompactABEntryKey = &kWAGRCompactABEntryKey;
static const void *kWAGRCompactSurfaceEntryKey = &kWAGRCompactSurfaceEntryKey;

static NSArray *WAGRCompactEntries(id self) {
    NSArray *keys = nil;
    NSDictionary *sections = nil;
    @try { keys = [self valueForKey:@"sectionKeys"]; sections = [self valueForKey:@"sections"]; }
    @catch (__unused NSException *e) { return @[]; }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *key in keys ?: @[]) {
        NSArray *items = [sections[key] isKindOfClass:NSArray.class] ? sections[key] : nil;
        if (items.count) [rows addObjectsFromArray:items];
    }
    return rows;
}

static NSInteger WAGRCompactNumberOfSections(id self, SEL _cmd, UITableView *table) {
    (void)self; (void)_cmd; (void)table; return 1;
}

static NSInteger WAGRCompactNumberOfRows(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)_cmd; (void)table; return section == 0 ? (NSInteger)WAGRCompactEntries(self).count : 0;
}

static id WAGRCompactEntryAtIndexPath(id self, SEL _cmd, NSIndexPath *indexPath) {
    (void)_cmd;
    NSArray *rows = WAGRCompactEntries(self);
    return indexPath.section == 0 && indexPath.row >= 0 && indexPath.row < (NSInteger)rows.count
        ? rows[(NSUInteger)indexPath.row] : nil;
}

static NSString *WAGRCompactNoHeader(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section; return nil;
}

static CGFloat WAGRCompactZeroSectionHeight(id self, SEL _cmd, UITableView *table, NSInteger section) {
    (void)self; (void)_cmd; (void)table; (void)section; return CGFLOAT_MIN;
}

static NSString *WAGRCompactForced(id value, BOOL overridden) {
    if (!overridden) return @"";
    if (!value) return @" · FORCE nil";
    NSString *text = [value description] ?: @"?";
    if (text.length > 40) text = [[text substringToIndex:40] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@" · FORCE %@", text];
}

static UITableViewCell *WAGRCompactABCell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    static NSString *reuse = @"WAGRCompactABCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGRABPropEntry *entry = WAGRCompactEntryAtIndexPath(self, NULL, indexPath);
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"abprop");
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    if (!entry) return cell;

    NSArray *runtimeObjects = nil;
    NSDictionary *nativeIndex = nil;
    @try { runtimeObjects = [self valueForKey:@"runtimeObjects"]; nativeIndex = [self valueForKey:@"nativeEntriesBySelector"]; }
    @catch (__unused NSException *e) {}
    id raw = nil;
    NSString *current = WAGRABPropsCurrentValue(entry, runtimeObjects ?: @[], &raw);
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod);
    NSDictionary *native = [nativeIndex[entry.selectorName] isKindOfClass:NSDictionary.class] ? nativeIndex[entry.selectorName] : nil;
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class] ? native[@"mobileconfig"] : nil;

    cell.textLabel.text = entry.selectorName ?: @"?";
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%@%@", current ?: @"?", WAGRCompactForced(forced, overridden)];
    if (native) {
        [detail appendFormat:@" · AB #%@", native[@"code"] ?: @"?"];
        NSString *param = [mc[@"parameter_name"] isKindOfClass:NSString.class] ? mc[@"parameter_name"] : nil;
        if (param.length) [detail appendFormat:@"\nMC %@", param];
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = overridden ? UIColor.systemCyanColor : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:NSSelectorFromString(@"wagr_compactABSwitchChanged:") forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRCompactABEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRCompactABSwitchChanged(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRCompactABEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName, entry.classMethod, entry.typeCode, @(sender.isOn));
    (void)WAGRRuntimeValueInstallHook(entry.className, entry.selectorName, entry.classMethod, entry.typeCode);
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"applyCurrentFilter"));
}

static UITableViewCell *WAGRCompactSurfaceCell(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    (void)_cmd;
    static NSString *reuse = @"WAGRCompactSurfaceCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    WAGREntry *entry = WAGRCompactEntryAtIndexPath(self, NULL, indexPath);
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"runtime");
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 0;
    if (!entry) return cell;

    id raw = nil;
    NSString *current = ((id (*)(id, SEL, id, id *))objc_msgSend)(self, NSSelectorFromString(@"currentForEntry:raw:"), entry, &raw);
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.isClassMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.isClassMethod);
    cell.textLabel.text = entry.selectorName ?: @"?";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@", entry.className ?: @"?", current ?: @"?", WAGRCompactForced(forced, overridden)];
    cell.detailTextLabel.textColor = overridden ? UIColor.systemCyanColor : WAGRMenuSecondaryTextColor();

    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) {
        UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : [UISwitch new];
        if (toggle != cell.accessoryView) {
            [toggle addTarget:self action:NSSelectorFromString(@"wagr_compactSurfaceSwitchChanged:") forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
        objc_setAssociatedObject(toggle, kWAGRCompactSurfaceEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toggle.on = overridden ? [forced boolValue] : [raw boolValue];
        toggle.onTintColor = overridden ? UIColor.systemCyanColor : UIColor.systemGreenColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRCompactSurfaceSwitchChanged(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    WAGREntry *entry = objc_getAssociatedObject(sender, kWAGRCompactSurfaceEntryKey);
    if (!entry) return;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode, @(sender.isOn));
    (void)WAGRRuntimeValueInstallHook(entry.className, entry.selectorName, entry.isClassMethod, entry.typeCode);
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"applyCurrentFilter"));
}

static void WAGRInstallCompactMethod(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method && method_getImplementation(method) != replacement) method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void WAGRRuntimeBrowserCompactUICtor(void) {
    @autoreleasepool {
        Class ab = NSClassFromString(@"WAGRABPropsBrowserVC");
        Class surface = NSClassFromString(@"WAGRSurfaceBrowserVC");
        for (Class cls in @[ab ?: NSObject.class, surface ?: NSObject.class]) {
            if (cls == NSObject.class) continue;
            WAGRInstallCompactMethod(cls, @selector(numberOfSectionsInTableView:), (IMP)WAGRCompactNumberOfSections);
            WAGRInstallCompactMethod(cls, @selector(tableView:numberOfRowsInSection:), (IMP)WAGRCompactNumberOfRows);
            WAGRInstallCompactMethod(cls, NSSelectorFromString(@"entryAtIndexPath:"), (IMP)WAGRCompactEntryAtIndexPath);
            WAGRInstallCompactMethod(cls, @selector(tableView:titleForHeaderInSection:), (IMP)WAGRCompactNoHeader);
            WAGRInstallCompactMethod(cls, @selector(tableView:titleForFooterInSection:), (IMP)WAGRCompactNoHeader);
            class_addMethod(cls, @selector(tableView:heightForHeaderInSection:), (IMP)WAGRCompactZeroSectionHeight, "d@:@@q");
            class_addMethod(cls, @selector(tableView:heightForFooterInSection:), (IMP)WAGRCompactZeroSectionHeight, "d@:@@q");
        }
        if (ab) {
            WAGRInstallCompactMethod(ab, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRCompactABCell);
            class_addMethod(ab, NSSelectorFromString(@"wagr_compactABSwitchChanged:"), (IMP)WAGRCompactABSwitchChanged, "v@:@");
        }
        if (surface) {
            WAGRInstallCompactMethod(surface, @selector(tableView:cellForRowAtIndexPath:), (IMP)WAGRCompactSurfaceCell);
            class_addMethod(surface, NSSelectorFromString(@"wagr_compactSurfaceSwitchChanged:"), (IMP)WAGRCompactSurfaceSwitchChanged, "v@:@");
        }
    }
}
