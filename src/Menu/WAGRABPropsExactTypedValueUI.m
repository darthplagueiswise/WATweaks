#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRLog.h"

// Final ABProps presentation repair.
//
// The live catalog already knows the exact Objective-C return ABI. Do not let
// MobileConfig semantic metadata turn a q/Q/i/etc getter into a BOOL control.
// Also, an instance receiver may be unavailable while the same ABProp value is
// present in the native gabp snapshot. In that case feed the native cache value
// to the existing full-screen object editor instead of opening an empty editor.

static UITableViewCell *(*gWAGRExactOriginalCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*gWAGRExactOriginalPresentEditor)(id, SEL, WAGRABPropEntry *, UIView *) = NULL;
static BOOL gWAGRExactTypedUIInstalled = NO;

static id WAGRExactKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRExactSetKVC(id object, NSString *key, id value) {
    if (!object || !key.length) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static WAGRABPropEntry *WAGRExactEntryAt(id self, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (!self || !indexPath || ![self respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(self, selector, indexPath); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSDictionary *WAGRExactNativeEntry(id self, WAGRABPropEntry *entry) {
    NSDictionary *index = WAGRExactKVC(self, @"nativeEntriesBySelector");
    id value = entry.selectorName.length ? index[entry.selectorName] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static id WAGRExactNativeValue(NSDictionary *native) {
    if (![native isKindOfClass:NSDictionary.class]) return nil;
    id direct = native[@"value"];
    if (direct && direct != NSNull.null) return direct;
    NSDictionary *server = [native[@"server_cache_value"] isKindOfClass:NSDictionary.class]
        ? native[@"server_cache_value"] : nil;
    id serverValue = server[@"value"];
    if (serverValue && serverValue != NSNull.null) return serverValue;
    NSDictionary *nativeEntry = [native[@"native_entry"] isKindOfClass:NSDictionary.class]
        ? native[@"native_entry"] : nil;
    id nested = nativeEntry[@"value"];
    return nested == NSNull.null ? nil : nested;
}

static BOOL WAGRExactJSONString(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length < 2) return NO;
    unichar first = [text characterAtIndex:0];
    if (first != '{' && first != '[') return NO;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return NO;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] || [object isKindOfClass:NSArray.class];
}

static NSString *WAGRExactTypeLabel(WAGRABPropEntry *entry, id nativeValue) {
    if (!entry) return @"?";
    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) return @"BOOL";
    if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode)) {
        if ([entry.typeCode isEqualToString:@"q"]) return @"INT64";
        if ([entry.typeCode isEqualToString:@"i"]) return @"INT32";
        if ([entry.typeCode isEqualToString:@"s"]) return @"INT16";
        return @"INTEGER";
    }
    if (WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode)) {
        if ([entry.typeCode isEqualToString:@"Q"]) return @"UINT64";
        if ([entry.typeCode isEqualToString:@"I"]) return @"UINT32";
        if ([entry.typeCode isEqualToString:@"S"]) return @"UINT16";
        return @"UNSIGNED";
    }
    if (WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) {
        return [entry.typeCode isEqualToString:@"f"] ? @"FLOAT" : @"DOUBLE";
    }
    if (WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        if (WAGRExactJSONString(nativeValue)) return @"JSON/STRING";
        if ([nativeValue isKindOfClass:NSString.class]) return @"STRING";
        return @"OBJECT";
    }
    return WAGRRuntimeValueTypeName(entry.typeCode) ?: entry.typeCode ?: @"?";
}

static void WAGRExactAppendTypeLabel(UITableViewCell *cell,
                                     WAGRABPropEntry *entry,
                                     id nativeValue) {
    NSString *label = WAGRExactTypeLabel(entry, nativeValue);
    NSString *detail = cell.detailTextLabel.text ?: @"";
    if (!label.length) return;
    if ([detail rangeOfString:label options:NSCaseInsensitiveSearch].location != NSNotFound) return;
    cell.detailTextLabel.text = detail.length
        ? [NSString stringWithFormat:@"%@ · %@", detail, label]
        : label;
}

static UITableViewCell *WAGRExactCell(id self, SEL _cmd,
                                      UITableView *tableView,
                                      NSIndexPath *indexPath) {
    UITableViewCell *cell = gWAGRExactOriginalCell
        ? gWAGRExactOriginalCell(self, _cmd, tableView, indexPath) : nil;
    if (!cell) return cell;

    WAGRABPropEntry *entry = WAGRExactEntryAt(self, indexPath);
    if (!entry) return cell;
    NSDictionary *native = WAGRExactNativeEntry(self, entry);
    id nativeValue = WAGRExactNativeValue(native);

    // Objective-C ABI is authoritative for the control family. If an integer
    // getter was rendered as a switch from MC native_type metadata, remove that
    // semantic coercion and let row tap open the exact numeric editor.
    if ((WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
         WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode) ||
         WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) &&
        [cell.accessoryView isKindOfClass:UISwitch.class]) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    if (WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        BOOL structured = WAGRExactJSONString(nativeValue) ||
                          [nativeValue isKindOfClass:NSDictionary.class] ||
                          [nativeValue isKindOfClass:NSArray.class];
        BOOL longText = [nativeValue isKindOfClass:NSString.class] &&
                        [(NSString *)nativeValue length] > 96;
        if (structured || longText) {
            // A large/structured value is unusable in a 100pt inline text field.
            // Row tap opens the full value inspector below.
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }

    WAGRExactAppendTypeLabel(cell, entry, nativeValue);
    return cell;
}

static void WAGRExactRefreshBrowser(id self) {
    SEL selector = NSSelectorFromString(@"applyCurrentFilter");
    if (![self respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(self, selector); }
    @catch (__unused NSException *exception) {}
}

static BOOL WAGRExactPushExistingFullEditor(id self,
                                             WAGRABPropEntry *entry,
                                             id sourceValue) {
    if (!self || !entry || !sourceValue) return NO;
    UINavigationController *navigationController =
        [self isKindOfClass:UIViewController.class]
            ? ((UIViewController *)self).navigationController : nil;
    if (!navigationController) return NO;

    Class editorClass = NSClassFromString(@"WAGRFullValueEditorVC");
    if (!editorClass || ![editorClass isSubclassOfClass:UIViewController.class]) return NO;
    UIViewController *editor = [editorClass new];
    if (!editor) return NO;

    BOOL json = WAGRExactJSONString(sourceValue) ||
                [sourceValue isKindOfClass:NSDictionary.class] ||
                [sourceValue isKindOfClass:NSArray.class];
    WAGRExactSetKVC(editor, @"targetClassName", entry.className ?: @"");
    WAGRExactSetKVC(editor, @"targetSelectorName", entry.selectorName ?: @"");
    WAGRExactSetKVC(editor, @"targetTypeCode", entry.typeCode ?: @"@");
    WAGRExactSetKVC(editor, @"targetMeta", @(entry.classMethod));
    WAGRExactSetKVC(editor, @"sourceValue", sourceValue);
    WAGRExactSetKVC(editor, @"preserveString", @([sourceValue isKindOfClass:NSString.class]));
    WAGRExactSetKVC(editor, @"validateJSON", @(json ||
        [entry.selectorName.lowercaseString containsString:@"json"] ||
        [entry.selectorName isEqualToString:@"wamo_abprops_list"]));
    WAGRExactSetKVC(editor, @"typedABPropsSchema",
                    @([entry.selectorName isEqualToString:@"wamo_abprops_list"]));

    __weak id weakSelf = self;
    dispatch_block_t completion = ^{
        id strongSelf = weakSelf;
        if (strongSelf) WAGRExactRefreshBrowser(strongSelf);
    };
    WAGRExactSetKVC(editor, @"completion", [completion copy]);
    [navigationController pushViewController:editor animated:YES];
    return YES;
}

static void WAGRExactPresentEditor(id self, SEL _cmd,
                                   WAGRABPropEntry *entry,
                                   UIView *sourceView) {
    if (!entry || !WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        if (gWAGRExactOriginalPresentEditor) {
            gWAGRExactOriginalPresentEditor(self, _cmd, entry, sourceView);
        }
        return;
    }

    NSArray *runtimeObjects = WAGRExactKVC(self, @"runtimeObjects") ?: @[];
    id raw = nil;
    (void)WAGRABPropsCurrentValue(entry, runtimeObjects, &raw);
    id forced = WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)
        ? WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod) : nil;
    NSDictionary *native = WAGRExactNativeEntry(self, entry);
    id cacheValue = WAGRExactNativeValue(native);
    id source = forced ?: raw ?: cacheValue;

    if (source && WAGRExactPushExistingFullEditor(self, entry, source)) return;
    if (gWAGRExactOriginalPresentEditor) {
        gWAGRExactOriginalPresentEditor(self, _cmd, entry, sourceView);
    }
}

static void WAGRExactTypedUIInstall(void) {
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (!cls) return;

    SEL cellSelector = @selector(tableView:cellForRowAtIndexPath:);
    Method cellMethod = class_getInstanceMethod(cls, cellSelector);
    IMP cellCurrent = cellMethod ? method_getImplementation(cellMethod) : NULL;
    if (cellMethod && cellCurrent != (IMP)WAGRExactCell) {
        gWAGRExactOriginalCell =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))cellCurrent;
        method_setImplementation(cellMethod, (IMP)WAGRExactCell);
    }

    SEL editorSelector = NSSelectorFromString(@"presentEditorForEntry:fromView:");
    Method editorMethod = class_getInstanceMethod(cls, editorSelector);
    IMP editorCurrent = editorMethod ? method_getImplementation(editorMethod) : NULL;
    if (editorMethod && editorCurrent != (IMP)WAGRExactPresentEditor) {
        gWAGRExactOriginalPresentEditor =
            (void (*)(id, SEL, WAGRABPropEntry *, UIView *))editorCurrent;
        method_setImplementation(editorMethod, (IMP)WAGRExactPresentEditor);
    }

    if (!gWAGRExactTypedUIInstalled) {
        gWAGRExactTypedUIInstalled = YES;
        WAGRLogAppend(@"[ABProps][UI] exact ABI type labels + cache-backed full value inspector installed");
    }
}

__attribute__((constructor))
static void WAGRABPropsExactTypedValueUICtor(void) {
    @autoreleasepool {
        // Install after InlineTypedUI, compact styling and the generic object
        // full-screen layer, so this remains the final ABProps semantic pass.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.80 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRExactTypedUIInstall(); });
    }
}
