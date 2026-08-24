#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stdlib.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsNativeStore.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"
#import "../Runtime/WAGRLog.h"
#import "WAGRMenuTheme.h"

// Final presentation layer for the WAAB account browser.
//
// The browser has two independent sources of type information:
//   1. Objective-C method return ABI (B/c/q/Q/f/d/@...), obtained live from the
//      loaded class method table. This is authoritative for installing a hook.
//   2. WAMCEvaluation's paramSpecifier native_type metadata. This can tell us
//      that an integer-backed parameter is semantically a BOOL.
//
// Never collapse every non-BOOL into a disclosure chevron. A settings/debug
// browser should expose the natural control directly in the row:
//   BOOL               -> UISwitch
//   signed/unsigned int-> numeric UITextField
//   float/double       -> decimal UITextField
//   NSString object    -> text UITextField
//   other object       -> disclosure / advanced editor on row tap
//
// This file intentionally installs after constructors have run so it remains
// the final cell renderer even when WAGRRuntimeBrowserCompactUI is linked before
// or after it. It changes Objective-C method-table metadata only; no __TEXT page
// is patched.

static const void *kWAGRInlineABEntryKey = &kWAGRInlineABEntryKey;
static const void *kWAGRInlineABInitialTextKey = &kWAGRInlineABInitialTextKey;
static const void *kWAGRInlineABSemanticTypeKey = &kWAGRInlineABSemanticTypeKey;
static BOOL gWAGRInlineABInstalled = NO;

static id WAGRInlineKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static WAGRABPropEntry *WAGRInlineEntryAt(id self, NSIndexPath *indexPath) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (![self respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(self, selector, indexPath);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSDictionary *WAGRInlineNativeEntry(id self, WAGRABPropEntry *entry) {
    NSDictionary *index = WAGRInlineKVC(self, @"nativeEntriesBySelector");
    id value = entry.selectorName.length ? index[entry.selectorName] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static uint64_t WAGRInlineSpecifier(NSDictionary *mc) {
    id value = mc[@"param_specifier_hex"];
    if ([value isKindOfClass:NSNumber.class]) return [value unsignedLongLongValue];
    if (![value isKindOfClass:NSString.class]) return 0;
    return strtoull([(NSString *)value UTF8String] ?: "0", NULL, 0);
}

static NSString *WAGRInlineParameterName(NSDictionary *native, NSDictionary *mc,
                                          WAGRABPropEntry *entry) {
    NSString *name = [native[@"name"] isKindOfClass:NSString.class] ? native[@"name"] : nil;
    if (name.length && ![name hasPrefix:@"ABProp "]) return name;

    NSString *parameter = [mc[@"parameter_name"] isKindOfClass:NSString.class]
        ? mc[@"parameter_name"] : nil;
    if (parameter.length) return parameter;

    NSString *runtimeName = WAGRMobileConfigRuntimeNameForSpecifier(WAGRInlineSpecifier(mc));
    if (runtimeName.length) {
        NSRange dot = [runtimeName rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location != NSNotFound && NSMaxRange(dot) < runtimeName.length) {
            return [runtimeName substringFromIndex:NSMaxRange(dot)];
        }
        return runtimeName;
    }
    return entry.selectorName ?: @"ABProp";
}

static BOOL WAGRInlineWireBool(id value, BOOL *known) {
    if (known) *known = NO;
    if ([value isKindOfClass:NSNumber.class]) {
        if (known) *known = YES;
        return [value boolValue];
    }
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *lower = [(NSString *)value lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] ||
        [lower isEqualToString:@"yes"]) {
        if (known) *known = YES;
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] ||
        [lower isEqualToString:@"no"]) {
        if (known) *known = YES;
        return NO;
    }
    return NO;
}

typedef NS_ENUM(uint8_t, WAGRInlineABControlType) {
    WAGRInlineABControlAdvanced = 0,
    WAGRInlineABControlBool = 1,
    WAGRInlineABControlInteger = 2,
    WAGRInlineABControlString = 3,
    WAGRInlineABControlFloating = 4,
};

static uint8_t WAGRInlineMCNativeType(NSDictionary *native) {
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? native[@"mobileconfig"] : nil;
    id value = mc[@"native_type"];
    return [value respondsToSelector:@selector(unsignedCharValue)]
        ? [value unsignedCharValue] : 0;
}

static WAGRInlineABControlType WAGRInlineControlType(WAGRABPropEntry *entry,
                                                      NSDictionary *native,
                                                      id raw) {
    if (!entry) return WAGRInlineABControlAdvanced;

    // The actual Objective-C ABI wins whenever it is unambiguous. In particular,
    // a real B/c getter must never lose its switch because translated metadata
    // is absent or stale.
    if (WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) return WAGRInlineABControlBool;
    if (WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) return WAGRInlineABControlFloating;

    if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode) ||
        WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode)) {
        // Some WAAB parameters are semantically bool while backed by a word-sized
        // getter. WAMCEvaluation native_type=1 is the additional proof required
        // before presenting those integer ABI methods as switches.
        return WAGRInlineMCNativeType(native) == 1
            ? WAGRInlineABControlBool : WAGRInlineABControlInteger;
    }

    if (WAGRRuntimeValueTypeIsObject(entry.typeCode)) {
        uint8_t nativeType = WAGRInlineMCNativeType(native);
        id wire = native[@"value"];
        if (nativeType == 3 || [raw isKindOfClass:NSString.class] ||
            [wire isKindOfClass:NSString.class]) {
            return WAGRInlineABControlString;
        }
    }
    return WAGRInlineABControlAdvanced;
}

static NSString *WAGRInlineValueText(WAGRInlineABControlType type,
                                      id effective,
                                      NSString *runtimeText,
                                      NSDictionary *native) {
    if (type == WAGRInlineABControlBool) {
        if ([effective respondsToSelector:@selector(boolValue)]) {
            return [effective boolValue] ? @"YES" : @"NO";
        }
        BOOL known = NO;
        BOOL value = WAGRInlineWireBool(native[@"value"], &known);
        if (known) return value ? @"YES" : @"NO";
    }
    if (effective && effective != NSNull.null) return [effective description] ?: @"?";
    id wire = native[@"value"];
    if (wire && wire != NSNull.null) return [wire description] ?: @"?";
    return runtimeText ?: @"?";
}

static void WAGRInlineRefresh(id self) {
    SEL selector = NSSelectorFromString(@"applyCurrentFilter");
    if (![self respondsToSelector:selector]) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(self, selector); }
    @catch (__unused NSException *exception) {}
}

static BOOL WAGRInlineInstallOverride(WAGRABPropEntry *entry, id value) {
    if (!entry || !value) return NO;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, value);
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className,
                                                  entry.selectorName,
                                                  entry.classMethod,
                                                  entry.typeCode);
    if (!installed) {
        WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.classMethod);
    }
    return installed;
}

static void WAGRInlineSwitchChanged(id self, __unused SEL _cmd, UISwitch *sender) {
    WAGRABPropEntry *entry = objc_getAssociatedObject(sender, kWAGRInlineABEntryKey);
    if (!entry) return;

    // NSNumber is converted by RuntimeValueStore according to the getter's real
    // ABI. For word-backed semantic BOOLs this therefore becomes integer 0/1;
    // for B/c it becomes the native boolean width.
    if (!WAGRInlineInstallOverride(entry, @(sender.isOn))) {
        sender.on = !sender.isOn;
    }
    WAGRInlineRefresh(self);
}

static BOOL WAGRInlineParseSigned(NSString *text, long long *outValue) {
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    long long value = 0;
    if (![scanner scanLongLong:&value] || !scanner.isAtEnd) return NO;
    if (outValue) *outValue = value;
    return YES;
}

static BOOL WAGRInlineParseUnsigned(NSString *text, unsigned long long *outValue) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed hasPrefix:@"-"]) return NO;
    char *end = NULL;
    unsigned long long value = strtoull(trimmed.UTF8String ?: "", &end, 10);
    if (!end || *end != '\0') return NO;
    if (outValue) *outValue = value;
    return YES;
}

static BOOL WAGRInlineParseDouble(NSString *text, double *outValue) {
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    double value = 0.0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd) return NO;
    if (outValue) *outValue = value;
    return YES;
}

static void WAGRInlineFieldCommit(id self, __unused SEL _cmd, UITextField *field) {
    WAGRABPropEntry *entry = objc_getAssociatedObject(field, kWAGRInlineABEntryKey);
    NSString *initial = objc_getAssociatedObject(field, kWAGRInlineABInitialTextKey) ?: @"";
    NSNumber *semanticNumber = objc_getAssociatedObject(field, kWAGRInlineABSemanticTypeKey);
    WAGRInlineABControlType semantic = (WAGRInlineABControlType)semanticNumber.unsignedCharValue;
    if (!entry) return;

    NSString *text = [field.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([text isEqualToString:initial]) return;

    id value = nil;
    BOOL valid = YES;
    if (WAGRRuntimeValueTypeIsSignedInteger(entry.typeCode)) {
        long long parsed = 0;
        valid = WAGRInlineParseSigned(text, &parsed);
        if (valid) value = @(parsed);
    } else if (WAGRRuntimeValueTypeIsUnsignedInteger(entry.typeCode)) {
        unsigned long long parsed = 0;
        valid = WAGRInlineParseUnsigned(text, &parsed);
        if (valid) value = @(parsed);
    } else if (WAGRRuntimeValueTypeIsFloatingPoint(entry.typeCode)) {
        double parsed = 0.0;
        valid = WAGRInlineParseDouble(text, &parsed);
        if (valid) value = @(parsed);
    } else if (WAGRRuntimeValueTypeIsObject(entry.typeCode) &&
               semantic == WAGRInlineABControlString) {
        value = text;
    } else {
        valid = NO;
    }

    if (!valid || !value || !WAGRInlineInstallOverride(entry, value)) {
        field.text = initial;
        field.textColor = UIColor.systemRedColor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            field.textColor = UIColor.labelColor;
        });
        return;
    }
    WAGRInlineRefresh(self);
}

static UITextField *WAGRInlineField(id self,
                                    WAGRABPropEntry *entry,
                                    WAGRInlineABControlType type,
                                    NSString *text,
                                    BOOL overridden) {
    CGFloat width = type == WAGRInlineABControlString ? 138.0 : 96.0;
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, width, 34.0)];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    field.textAlignment = NSTextAlignmentRight;
    field.adjustsFontSizeToFitWidth = YES;
    field.minimumFontSize = 11.0;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.returnKeyType = UIReturnKeyDone;
    field.text = text ?: @"";
    field.textColor = overridden ? UIColor.systemBlueColor : UIColor.labelColor;
    field.tintColor = overridden ? UIColor.systemBlueColor : UIColor.labelColor;

    if (type == WAGRInlineABControlFloating) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.placeholder = @"decimal";
    } else if (type == WAGRInlineABControlInteger) {
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.placeholder = @"inteiro";
    } else {
        field.keyboardType = UIKeyboardTypeDefault;
        field.placeholder = @"texto";
    }

    objc_setAssociatedObject(field, kWAGRInlineABEntryKey, entry,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, kWAGRInlineABInitialTextKey, text ?: @"",
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(field, kWAGRInlineABSemanticTypeKey, @(type),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [field addTarget:self action:NSSelectorFromString(@"wagr_inlineABFieldCommit:")
      forControlEvents:UIControlEventEditingDidEnd];
    return field;
}

static UITableViewCell *WAGRInlineABCell(id self, __unused SEL _cmd,
                                         UITableView *table,
                                         NSIndexPath *indexPath) {
    static NSString *reuse = @"WAGRInlineTypedABCell";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuse];
    }

    WAGRABPropEntry *entry = WAGRInlineEntryAt(self, indexPath);
    WAGRMenuApplyCellStyle(cell, indexPath.row, entry.selectorName ?: @"abprop");
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!entry) return cell;

    NSArray *runtimeObjects = WAGRInlineKVC(self, @"runtimeObjects") ?: @[];
    id raw = nil;
    NSString *runtimeText = WAGRABPropsCurrentValue(entry, runtimeObjects, &raw) ?: @"?";
    BOOL overridden = WAGRRuntimeValueHasOverride(entry.className,
                                                   entry.selectorName,
                                                   entry.classMethod);
    id forced = WAGRRuntimeValueOverride(entry.className, entry.selectorName, entry.classMethod);
    id effective = overridden ? forced : raw;
    NSDictionary *native = WAGRInlineNativeEntry(self, entry) ?: @{};
    NSDictionary *mc = [native[@"mobileconfig"] isKindOfClass:NSDictionary.class]
        ? native[@"mobileconfig"] : @{};
    WAGRInlineABControlType control = WAGRInlineControlType(entry, native, raw);

    cell.textLabel.text = WAGRInlineParameterName(native, mc, entry);
    NSString *display = WAGRInlineValueText(control, effective, runtimeText, native);
    NSString *code = [native[@"code"] description];
    NSString *typeName = WAGRRuntimeValueTypeName(entry.typeCode) ?: entry.typeCode ?: @"?";

    if (code.length) {
        if (control == WAGRInlineABControlBool) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · AB %@%@",
                display ?: @"?", code, overridden ? @" · override" : @""];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · AB %@ · %@%@",
                display ?: @"?", code, typeName, overridden ? @" · override" : @""];
        }
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
            display ?: @"?", typeName, overridden ? @" · override" : @""];
    }
    cell.detailTextLabel.textColor = overridden ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;

    if (control == WAGRInlineABControlBool) {
        UISwitch *toggle = [UISwitch new];
        BOOL known = NO;
        BOOL on = NO;
        if (effective && [effective respondsToSelector:@selector(boolValue)]) {
            on = [effective boolValue];
            known = YES;
        } else {
            on = WAGRInlineWireBool(native[@"value"], &known);
        }
        toggle.on = known ? on : NO;
        toggle.onTintColor = overridden ? UIColor.systemBlueColor : UIColor.systemGreenColor;
        objc_setAssociatedObject(toggle, kWAGRInlineABEntryKey, entry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:NSSelectorFromString(@"wagr_inlineABSwitchChanged:")
          forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (control == WAGRInlineABControlInteger ||
               control == WAGRInlineABControlFloating ||
               (control == WAGRInlineABControlString &&
                (effective == nil || [effective isKindOfClass:NSString.class] ||
                 [native[@"value"] isKindOfClass:NSString.class]))) {
        cell.accessoryView = WAGRInlineField(self, entry, control, display, overridden);
    } else {
        // Only genuinely complex values keep the advanced-editor disclosure.
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void WAGRInlineInstall(void) {
    Class cls = NSClassFromString(@"WAGRABPropsBrowserVC");
    if (!cls) return;

    Method cellMethod = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    if (!cellMethod) return;
    if (method_getImplementation(cellMethod) != (IMP)WAGRInlineABCell) {
        method_setImplementation(cellMethod, (IMP)WAGRInlineABCell);
    }

    SEL switchSelector = NSSelectorFromString(@"wagr_inlineABSwitchChanged:");
    if (!class_getInstanceMethod(cls, switchSelector)) {
        class_addMethod(cls, switchSelector, (IMP)WAGRInlineSwitchChanged, "v@:@");
    }
    SEL fieldSelector = NSSelectorFromString(@"wagr_inlineABFieldCommit:");
    if (!class_getInstanceMethod(cls, fieldSelector)) {
        class_addMethod(cls, fieldSelector, (IMP)WAGRInlineFieldCommit, "v@:@");
    }

    if (!gWAGRInlineABInstalled) {
        gWAGRInlineABInstalled = YES;
        WAGRLogAppend(@"[ABProps][UI] final inline ABI-aware cell renderer installed");
    }
}

__attribute__((constructor))
static void WAGRInlineABUICtor(void) {
    @autoreleasepool {
        // Queue after all image constructors so CompactUI cannot overwrite this
        // renderer just because of link/source order. Retry once for delayed
        // class registration in sideloaded builds.
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRInlineInstall(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRInlineInstall(); });
    }
}
