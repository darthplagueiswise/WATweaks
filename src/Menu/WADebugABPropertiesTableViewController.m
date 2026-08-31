#import "WADebugABPropertiesTableViewController.h"

#import "../Runtime/WAGRABPropsNativeOverrideEngine.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRLog.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

// The 26.33 RC removed the controller class, but retained its complete native
// UI substrate in WADebugMenuBase/WAFoundation. Keeping every reference below
// dynamic is intentional: WATweaks must not link an SDK-time surrogate class
// or depend on a private framework stub that is unavailable to the linker.

static NSString * const kWAGRABPropsControllerName = @"WADebugABPropertiesTableViewController";
static NSString * const kWAGRABPropsNativeCellName = @"_TtC15WADebugMenuBase28WADebugKeyValueTableViewCell";
static const void *kWAGRABPropsStateKey = &kWAGRABPropsStateKey;
static Class gWAGRABPropsNativeBaseClass = Nil;

@interface WAGRRecreatedABPropsState : NSObject
@property(nonatomic, strong) id userContext;
@property(nonatomic, strong) id abProperties;
@property(nonatomic, copy) NSArray *runtimeObjects;
@property(nonatomic, copy) NSArray<WAGRABPropEntry *> *allEntries;
@property(nonatomic, copy) NSArray<WAGRABPropEntry *> *filteredEntries;
@property(nonatomic, strong) NSMapTable<UITableViewCell *, WAGRABPropEntry *> *entriesByCell;
@property(nonatomic, strong) id nativeSearchController;
@property(nonatomic, assign) NSUInteger scanGeneration;
@property(nonatomic, assign) BOOL scanStarted;
@end

@implementation WAGRRecreatedABPropsState
@end

static WAGRRecreatedABPropsState *WAGRABPropsState(id controller, BOOL create) {
    if (!controller) return nil;
    WAGRRecreatedABPropsState *state = objc_getAssociatedObject(controller,
                                                                 kWAGRABPropsStateKey);
    if (!state && create) {
        state = [WAGRRecreatedABPropsState new];
        state.runtimeObjects = @[];
        state.allEntries = @[];
        state.filteredEntries = @[];
        state.entriesByCell = [NSMapTable weakToStrongObjectsMapTable];
        objc_setAssociatedObject(controller, kWAGRABPropsStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static const char *WAGRABPropsSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABPropsMethodMatches(Class cls, SEL selector,
                                      unsigned int arguments,
                                      char returnType) {
    Method method = cls && selector ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABPropsSkipTypeQualifiers(raw)[0] == returnType;
}

static BOOL WAGRABPropsMethodEncodingMatches(Class cls, SEL selector,
                                              const char *expected) {
    Method method = cls && selector ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && expected && strcmp(encoding, expected) == 0;
}

static id WAGRABPropsObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (!WAGRABPropsMethodMatches([target class], selector, 2, '@')) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRABPropsSendObject(id target, NSString *selectorName, id value) {
    if (!target || !selectorName.length) return;
    SEL selector = NSSelectorFromString(selectorName);
    if (!WAGRABPropsMethodMatches([target class], selector, 3, 'v')) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value); }
    @catch (__unused NSException *exception) {}
}

static NSString *WAGRABPropsLocalizedTitle(void) {
    NSString *key = @"OVERRIDE_ABPROPS";
    NSString *value = [NSBundle.mainBundle localizedStringForKey:key value:nil table:nil];
    if (!value.length || [value isEqualToString:key]) return @"Override ABProps";
    return value;
}

static NSString *WAGRABPropsLocalizedOverrideTitle(NSString *selectorName) {
    NSString *key = @"OVERRIDE_ABPROP:";
    NSString *format = [NSBundle.mainBundle localizedStringForKey:key value:nil table:nil];
    if (!format.length || [format isEqualToString:key]) format = @"Override %@";
    if ([format containsString:@"%@"]) {
        return [NSString stringWithFormat:format, selectorName ?: @"ABProp"];
    }
    return [NSString stringWithFormat:@"%@ %@", format, selectorName ?: @"ABProp"];
}

static NSString *WAGRABPropsFamily(WAGRABPropEntry *entry) {
    NSString *selector = entry.selectorName ?: @"";
    NSString *prefix = [[selector componentsSeparatedByString:@"_"] firstObject];
    if (prefix.length && ![prefix isEqualToString:selector]) return prefix.uppercaseString;
    return entry.categoryName.length ? entry.categoryName : @"OTHER";
}

static NSString *WAGRABPropsCompactValue(WAGRABPropEntry *entry,
                                          NSArray *runtimeObjects,
                                          id *rawValue) {
    NSString *value = WAGRABPropsCurrentValue(entry, runtimeObjects, rawValue) ?: @"nil";
    value = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (value.length > 96) value = [[value substringToIndex:96] stringByAppendingString:@"…"];
    return value;
}

static UITableViewCell *WAGRABPropsNativeCell(WAGRABPropEntry *entry,
                                              NSArray *runtimeObjects,
                                              BOOL disclosure,
                                              BOOL readEffectiveValue) {
    Class cellClass = NSClassFromString(kWAGRABPropsNativeCellName);
    if (!cellClass || ![cellClass isSubclassOfClass:UITableViewCell.class]) {
        cellClass = UITableViewCell.class;
    }
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cellClass, @selector(alloc));
    UITableViewCell *cell = ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(
        allocated, @selector(initWithStyle:reuseIdentifier:),
        UITableViewCellStyleSubtitle, nil);
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:nil];

    id overrideValue = entry.stableID.length
        ? WAGRABPropsNativeTrackedOverrides()[entry.stableID] : nil;
    BOOL overridden = overrideValue != nil;
    NSString *value = readEffectiveValue
        ? WAGRABPropsCompactValue(entry, runtimeObjects, NULL)
        : (overridden ? [overrideValue description] : nil);
    NSString *type = entry.typeName.length ? entry.typeName : entry.typeCode;
    cell.textLabel.text = entry.selectorName ?: @"ABProp";
    cell.detailTextLabel.text = value.length
        ? [NSString stringWithFormat:@"%@AB %@ · %@ · %@",
            overridden ? @"✓ " : @"", entry.stableID ?: @"?", type ?: @"?", value]
        : [NSString stringWithFormat:@"AB %@ · %@", entry.stableID ?: @"?", type ?: @"?"];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = disclosure ? UITableViewCellAccessoryDisclosureIndicator
                                    : UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

static void WAGRABPropsReloadNativeSections(id controller);
static void WAGRABPropsOpenEditor(id controller, WAGRABPropEntry *entry);

static id WAGRABPropsCreateNativeSection(NSString *header) {
    Class sectionClass = NSClassFromString(@"WATableSection");
    if (!sectionClass) return nil;
    id section = ((id (*)(id, SEL))objc_msgSend)((id)sectionClass, @selector(new));
    if (header.length) WAGRABPropsSendObject(section, @"setHeaderText:", header);
    return section;
}

static id WAGRABPropsAddNativeRow(id section,
                                  UITableViewCell *cell,
                                  dispatch_block_t handler,
                                  dispatch_block_t editHandler,
                                  BOOL editable) {
    Class rowClass = NSClassFromString(@"WATableRow");
    if (!section || !rowClass || !cell) return nil;
    if (!WAGRABPropsMethodEncodingMatches(rowClass, @selector(initWithCell:),
                                           "@24@0:8@16")) return nil;
    id rowAlloc = ((id (*)(id, SEL))objc_msgSend)((id)rowClass, @selector(alloc));
    id row = ((id (*)(id, SEL, id))objc_msgSend)(rowAlloc,
                                                  @selector(initWithCell:), cell);
    if (!row) return nil;
    SEL handlerSelector = NSSelectorFromString(@"setHandler:");
    SEL editHandlerSelector = NSSelectorFromString(@"setEditHandler:");
    if (handler &&
        WAGRABPropsMethodEncodingMatches([row class], handlerSelector,
                                         "v24@0:8@?16")) {
        ((void (*)(id, SEL, id))objc_msgSend)(row, handlerSelector, [handler copy]);
    }
    if (editHandler &&
        WAGRABPropsMethodEncodingMatches([row class], editHandlerSelector,
                                         "v24@0:8@?16")) {
        ((void (*)(id, SEL, id))objc_msgSend)(row, editHandlerSelector,
                                              [editHandler copy]);
    }
    SEL editableSelector = NSSelectorFromString(@"setEditable:");
    if (WAGRABPropsMethodEncodingMatches([row class], editableSelector,
                                         "v20@0:8B16")) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(row, editableSelector, editable);
    }
    SEL addSelector = NSSelectorFromString(@"addRow:");
    if (!WAGRABPropsMethodEncodingMatches([section class], addSelector,
                                           "v24@0:8@16")) return nil;
    ((void (*)(id, SEL, id))objc_msgSend)(section, addSelector, row);
    return row;
}

static void WAGRABPropsAddSectionToController(id controller, id section) {
    if (!controller || !section) return;
    SEL addSelector = NSSelectorFromString(@"addSection:");
    if (WAGRABPropsMethodEncodingMatches([controller class], addSelector,
                                         "@24@0:8@16")) {
        ((id (*)(id, SEL, id))objc_msgSend)(controller, addSelector, section);
    }
}

static void WAGRABPropsClearSections(id controller) {
    id sections = WAGRABPropsObjectNoArg(controller, @"sections");
    if ([sections respondsToSelector:@selector(removeAllObjects)]) [sections removeAllObjects];
}

static void WAGRABPropsReloadTable(id controller) {
    // reloadAllSections invokes setUpTableView again in WAStaticTableViewController.
    // We have already rebuilt its mutable sections array, so calling it here
    // would recursively rebuild the controller. Reload only the native table.
    if ([controller isKindOfClass:UITableViewController.class]) {
        [[(UITableViewController *)controller tableView] reloadData];
    }
}

static void WAGRABPropsPresentError(id controller, NSString *title, NSString *message) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"ABProps"
        message:message ?: @"Unknown error" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)controller presentViewController:alert animated:YES completion:nil];
}

static id WAGRABPropsTypedValue(NSString *text, NSString *typeCode,
                                NSString **errorText) {
    const char *raw = WAGRABPropsSkipTypeQualifiers(typeCode.UTF8String);
    char type = raw[0];
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (type == '@') return text ?: @"";

    if (type == 'B' || type == 'c' || type == 'C') {
        NSString *lower = trimmed.lowercaseString;
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] ||
            [lower isEqualToString:@"1"]) return @YES;
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] ||
            [lower isEqualToString:@"0"]) return @NO;
        if (errorText) *errorText = @"Use true/false or 1/0.";
        return nil;
    }

    if (strchr("sSiIlLqQ", type)) {
        errno = 0;
        char *end = NULL;
        if (strchr("SILQ", type)) {
            unsigned long long value = strtoull(trimmed.UTF8String, &end, 10);
            if (!errno && end && end != trimmed.UTF8String && *end == '\0') return @(value);
        } else {
            long long value = strtoll(trimmed.UTF8String, &end, 10);
            if (!errno && end && end != trimmed.UTF8String && *end == '\0') return @(value);
        }
        if (errorText) *errorText = @"Enter a valid integer.";
        return nil;
    }

    if (type == 'f' || type == 'd') {
        errno = 0;
        char *end = NULL;
        double value = strtod(trimmed.UTF8String, &end);
        if (!errno && end && end != trimmed.UTF8String && *end == '\0') return @(value);
        if (errorText) *errorText = @"Enter a valid decimal number.";
        return nil;
    }

    if (errorText) *errorText = [NSString stringWithFormat:@"Unsupported ABI type: %@",
                                 typeCode ?: @"?"];
    return nil;
}

static void WAGRABPropsOpenEditor(id controller, WAGRABPropEntry *entry) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(controller, NO);
    if (!state || !entry.stableID.length) {
        WAGRABPropsPresentError(controller, @"Override ABProp",
                                @"The generated getter has no verified stable ID.");
        return;
    }

    Class inputClass = NSClassFromString(@"WADebugInputViewController");
    SEL initializer = NSSelectorFromString(@"initWithCompletionHandler:");
    if (!inputClass ||
        !WAGRABPropsMethodEncodingMatches(inputClass, initializer,
                                           "@24@0:8@?16")) {
        WAGRABPropsPresentError(controller, @"Override ABProp",
                                @"WADebugInputViewController is not loaded with the expected ABI.");
        return;
    }

    id rawValue = nil;
    WAGRABPropsCurrentValue(entry, state.runtimeObjects, &rawValue);
    NSString *initial = [rawValue isKindOfClass:NSString.class]
        ? rawValue : ([rawValue description] ?: @"");
    __weak id weakController = controller;
    id completion = [^(NSString *text) {
        id strongController = weakController;
        if (!strongController) return;
        NSString *parseError = nil;
        id value = WAGRABPropsTypedValue(text ?: @"", entry.typeCode, &parseError);
        if (!value) {
            WAGRABPropsPresentError(strongController, @"Invalid ABProp value", parseError);
            return;
        }
        NSError *writeError = nil;
        NSString *diagnostic = nil;
        BOOL applied = WAGRABPropsNativeSetOverride(entry.stableID, value,
                                                     state.userContext,
                                                     &writeError, &diagnostic);
        if (!applied) {
            WAGRABPropsPresentError(strongController, @"ABProp not applied",
                writeError.localizedDescription ?: diagnostic ?: @"Native writer rejected the value.");
            return;
        }
        WAGRLogAppendF(@"[WADebugABProperties] native override %@ (%@) = %@; %@",
                       entry.selectorName, entry.stableID, value, diagnostic ?: @"verified");
        WAGRABPropsReloadNativeSections(strongController);
    } copy];

    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)inputClass, @selector(alloc));
    UIViewController *input = ((id (*)(id, SEL, id))objc_msgSend)(allocated,
        initializer, completion);
    if (!input) {
        WAGRABPropsPresentError(controller, @"Override ABProp",
                                @"WADebugInputViewController could not be initialized.");
        return;
    }

    WAGRABPropsSendObject(input, @"setNavigationTitle:",
        WAGRABPropsLocalizedOverrideTitle(entry.selectorName));
    WAGRABPropsSendObject(input, @"setInitialText:", initial);
    WAGRABPropsSendObject(input, @"setPlaceholderText:", entry.typeName ?: entry.typeCode);
    const char *type = WAGRABPropsSkipTypeQualifiers(entry.typeCode.UTF8String);
    SEL keyboardSelector = NSSelectorFromString(@"setKeyboardType:");
    if (strchr("BcCsSiIlLqQ", type[0]) &&
        WAGRABPropsMethodEncodingMatches([input class], keyboardSelector,
                                         "v24@0:8q16")) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(input, keyboardSelector,
                                                     UIKeyboardTypeNumbersAndPunctuation);
    } else if ((type[0] == 'f' || type[0] == 'd') &&
               WAGRABPropsMethodEncodingMatches([input class], keyboardSelector,
                                                 "v24@0:8q16")) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(input, keyboardSelector,
                                                     UIKeyboardTypeDecimalPad);
    }
    if (type[0] == 'B' || type[0] == 'c' || type[0] == 'C') {
        WAGRABPropsSendObject(input, @"setPossibleValuesTitle:", @"Value");
        WAGRABPropsSendObject(input, @"setPossibleValues:", @[@"true", @"false"]);
    }

    UIViewController *owner = (UIViewController *)controller;
    if (owner.navigationController) {
        [owner.navigationController pushViewController:input animated:YES];
    } else {
        [owner presentViewController:[[UINavigationController alloc]
            initWithRootViewController:input] animated:YES completion:nil];
    }
}

static void WAGRABPropsReloadNativeSections(id controller) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(controller, NO);
    if (!state) return;
    WAGRABPropsClearSections(controller);
    [state.entriesByCell removeAllObjects];

    if (!state.allEntries.count) {
        id section = WAGRABPropsCreateNativeSection(@"AB PROPERTIES");
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = state.scanStarted ? @"Loading generated ABProps…"
                                               : @"No generated ABProps found";
        cell.detailTextLabel.text = @"WAContext.abProperties";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        WAGRABPropsAddNativeRow(section, cell, nil, nil, NO);
        WAGRABPropsAddSectionToController(controller, section);
        WAGRABPropsReloadTable(controller);
        return;
    }

    NSMutableDictionary<NSString *, NSMutableArray<WAGRABPropEntry *> *> *families =
        [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in state.allEntries) {
        NSString *family = WAGRABPropsFamily(entry);
        if (!families[family]) families[family] = [NSMutableArray array];
        [families[family] addObject:entry];
    }
    NSArray<NSString *> *familyNames = [families.allKeys
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSDictionary *tracked = WAGRABPropsNativeTrackedOverrides();

    __weak id weakController = controller;
    for (NSString *family in familyNames) {
        id section = WAGRABPropsCreateNativeSection(family);
        NSArray<WAGRABPropEntry *> *entries = [families[family]
            sortedArrayUsingComparator:^NSComparisonResult(WAGRABPropEntry *left,
                                                            WAGRABPropEntry *right) {
                return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
            }];
        for (WAGRABPropEntry *entry in entries) {
            UITableViewCell *cell = WAGRABPropsNativeCell(entry, state.runtimeObjects,
                                                          YES, NO);
            [state.entriesByCell setObject:entry forKey:cell];
            BOOL overridden = tracked[entry.stableID] != nil;
            dispatch_block_t open = ^{
                id owner = weakController;
                if (owner) WAGRABPropsOpenEditor(owner, entry);
            };
            dispatch_block_t clear = overridden ? ^{
                id owner = weakController;
                WAGRRecreatedABPropsState *liveState = WAGRABPropsState(owner, NO);
                NSError *error = nil;
                NSString *diagnostic = nil;
                if (!WAGRABPropsNativeClearOverride(entry.stableID,
                                                     liveState.userContext,
                                                     &error, &diagnostic)) {
                    WAGRABPropsPresentError(owner, @"ABProp not cleared",
                        error.localizedDescription ?: diagnostic);
                    return;
                }
                WAGRABPropsReloadNativeSections(owner);
            } : nil;
            WAGRABPropsAddNativeRow(section, cell, open, clear, overridden);
        }
        WAGRABPropsAddSectionToController(controller, section);
    }

    if ([controller isKindOfClass:UIViewController.class]) {
        ((UIViewController *)controller).title = [NSString stringWithFormat:@"%@ (%lu)",
            WAGRABPropsLocalizedTitle(), (unsigned long)state.allEntries.count];
    }
    WAGRABPropsReloadTable(controller);
}

static void WAGRABPropsBeginScan(id controller) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(controller, NO);
    if (!state || state.scanStarted || !state.abProperties) return;
    state.scanStarted = YES;
    state.scanGeneration += 1;
    NSUInteger generation = state.scanGeneration;
    NSArray *objects = @[state.abProperties];
    state.runtimeObjects = objects;
    WAGRABPropsReloadNativeSections(controller);

    __weak id weakController = controller;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        dispatch_async(dispatch_get_main_queue(), ^{
            id owner = weakController;
            WAGRRecreatedABPropsState *liveState = WAGRABPropsState(owner, NO);
            if (!owner || !liveState || liveState.scanGeneration != generation) return;
            liveState.allEntries = entries ?: @[];
            liveState.filteredEntries = liveState.allEntries;
            WAGRABPropsReloadNativeSections(owner);
            WAGRLogAppendF(@"[WADebugABProperties] native table loaded %lu generated getters from %@",
                           (unsigned long)entries.count,
                           NSStringFromClass([liveState.abProperties class]));
        });
    });
}

static void WAGRABPropsInstallNativeSearch(id controller) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(controller, NO);
    if (!state || state.nativeSearchController) return;
    Class searchClass = NSClassFromString(@"WASearchController");
    SEL initializer = NSSelectorFromString(@"initWithHostViewController:searchBar:tableStyle:");
    if (!searchClass ||
        !WAGRABPropsMethodEncodingMatches(searchClass, initializer,
                                           "@40@0:8@16@24q32")) {
        WAGRLogAppend(@"[WADebugABProperties] WASearchController ABI unavailable; native table remains browsable");
        return;
    }

    UISearchBar *bar = [UISearchBar new];
    bar.placeholder = @"Search ABProp, stable ID or family";
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)searchClass, @selector(alloc));
    id search = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
        allocated, initializer, controller, bar, UITableViewStyleInsetGrouped);
    if (!search) return;
    WAGRABPropsSendObject(search, @"setDelegate:", controller);
    state.nativeSearchController = search;

    id system = WAGRABPropsObjectNoArg(search, @"systemSearchController");
    if ([system isKindOfClass:UISearchController.class] &&
        [controller isKindOfClass:UIViewController.class]) {
        UIViewController *viewController = controller;
        viewController.navigationItem.searchController = system;
        viewController.navigationItem.hidesSearchBarWhenScrolling = NO;
        viewController.definesPresentationContext = YES;
    }
}

#pragma mark - Dynamic native controller IMPs

static id WAGRABPropsInitWithInsetGroupedAndUserContext(id self, __unused SEL command,
                                                         id userContext) {
    if (!gWAGRABPropsNativeBaseClass) return nil;
    struct objc_super superInfo = { self, gWAGRABPropsNativeBaseClass };
    self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superInfo, NSSelectorFromString(@"initWithInsetGrouped"));
    if (!self) return nil;
    WAGRRecreatedABPropsState *state = WAGRABPropsState(self, YES);
    state.userContext = userContext;
    state.abProperties = WAGRABPropsObjectNoArg(userContext, @"abProperties");
    if ([self isKindOfClass:UIViewController.class]) {
        ((UIViewController *)self).title = WAGRABPropsLocalizedTitle();
    }
    return self;
}

static id WAGRABPropsInitWithUserContext(id self, SEL command, id userContext) {
    return WAGRABPropsInitWithInsetGroupedAndUserContext(self, command, userContext);
}

static id WAGRABPropsUserContext(id self, __unused SEL command) {
    return WAGRABPropsState(self, NO).userContext;
}

static id WAGRABPropsABProperties(id self, __unused SEL command) {
    return WAGRABPropsState(self, NO).abProperties;
}

static void WAGRABPropsSetUpTableView(id self, SEL command) {
    if (gWAGRABPropsNativeBaseClass) {
        struct objc_super superInfo = { self, gWAGRABPropsNativeBaseClass };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, command);
    }
    WAGRABPropsReloadNativeSections(self);
}

static void WAGRABPropsViewDidLoad(id self, SEL command) {
    if (gWAGRABPropsNativeBaseClass) {
        struct objc_super superInfo = { self, gWAGRABPropsNativeBaseClass };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, command);
    }
    WAGRABPropsInstallNativeSearch(self);
    WAGRABPropsBeginScan(self);
}

static void WAGRABPropsWillDisplayCell(id self, __unused SEL command,
                                        __unused UITableView *tableView,
                                        UITableViewCell *cell,
                                        __unused NSIndexPath *indexPath) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(self, NO);
    WAGRABPropEntry *entry = [state.entriesByCell objectForKey:cell];
    if (!entry) return;

    id rawValue = nil;
    NSString *value = WAGRABPropsCompactValue(entry, state.runtimeObjects, &rawValue);
    id overrideValue = entry.stableID.length
        ? WAGRABPropsNativeTrackedOverrides()[entry.stableID] : nil;
    NSString *type = entry.typeName.length ? entry.typeName : entry.typeCode;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@AB %@ · %@ · %@",
        overrideValue ? @"✓ " : @"", entry.stableID ?: @"?", type ?: @"?",
        value ?: @"nil"];
}

static void WAGRABPropsSearchUpdate(id self, __unused SEL command,
                                     id searchController, NSString *query) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(self, NO);
    if (!state) return;
    NSArray<NSString *> *tokens = [[query lowercaseString]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<WAGRABPropEntry *> *filtered = [NSMutableArray array];
    for (WAGRABPropEntry *entry in state.allEntries) {
        NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@ %@ %@",
            entry.selectorName ?: @"", entry.stableID ?: @"", entry.typeName ?: @"",
            WAGRABPropsFamily(entry), entry.className ?: @""] lowercaseString];
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (token.length && [haystack rangeOfString:token].location == NSNotFound) {
                matches = NO;
                break;
            }
        }
        if (matches) [filtered addObject:entry];
    }
    state.filteredEntries = filtered;
    SEL reloadSelector = NSSelectorFromString(@"reloadData");
    if (WAGRABPropsMethodMatches([searchController class], reloadSelector, 2, 'v')) {
        ((void (*)(id, SEL))objc_msgSend)(searchController, reloadSelector);
    }
}

static NSInteger WAGRABPropsSearchSectionCount(__unused id self, __unused SEL command,
                                                __unused id searchController) {
    return 1;
}

static NSInteger WAGRABPropsSearchRowCount(id self, __unused SEL command,
                                            __unused id searchController,
                                            NSInteger section) {
    return section == 0 ? (NSInteger)WAGRABPropsState(self, NO).filteredEntries.count : 0;
}

static UITableViewCell *WAGRABPropsSearchCell(id self, __unused SEL command,
                                              __unused id searchController,
                                              NSIndexPath *indexPath) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(self, NO);
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)state.filteredEntries.count) {
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:nil];
    }
    return WAGRABPropsNativeCell(state.filteredEntries[(NSUInteger)indexPath.row],
                                 state.runtimeObjects, YES, YES);
}

static void WAGRABPropsSearchSelect(id self, __unused SEL command,
                                    id searchController, NSIndexPath *indexPath) {
    WAGRRecreatedABPropsState *state = WAGRABPropsState(self, NO);
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)state.filteredEntries.count) return;
    SEL activeSelector = NSSelectorFromString(@"setActive:animated:");
    if (WAGRABPropsMethodEncodingMatches([searchController class], activeSelector,
                                         "v24@0:8B16B20")) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(searchController,
                                                     activeSelector, NO, YES);
    }
    WAGRABPropsOpenEditor(self, state.filteredEntries[(NSUInteger)indexPath.row]);
}

static NSString *WAGRABPropsSearchHeader(__unused id self, __unused SEL command,
                                         __unused id searchController,
                                         __unused NSInteger section) {
    return WAGRABPropsLocalizedTitle();
}

static BOOL WAGRABPropsSearchCanEdit(__unused id self, __unused SEL command,
                                     __unused id searchController,
                                     __unused NSIndexPath *indexPath) {
    return NO;
}

static NSInteger WAGRABPropsSearchEditingStyle(__unused id self, __unused SEL command,
                                                __unused id searchController,
                                                __unused NSIndexPath *indexPath) {
    return UITableViewCellEditingStyleNone;
}

static CGFloat WAGRABPropsSearchHeaderHeight(__unused id self, __unused SEL command,
                                              __unused id searchController,
                                              __unused NSInteger section) {
    return 0.0;
}

static UIView *WAGRABPropsSearchHeaderView(__unused id self, __unused SEL command,
                                           __unused id searchController,
                                           __unused NSInteger section) {
    return nil;
}

static BOOL WAGRABPropsSearchEmpty(__unused id self, __unused SEL command,
                                   __unused id searchController) {
    return NO;
}

static void WAGRABPropsNoOp(__unused id self, __unused SEL command,
                            __unused id argument) {}

static BOOL WAGRABPropsAddMethod(Class cls, NSString *selectorName,
                                  IMP implementation, const char *types) {
    return cls && selectorName.length && implementation && types &&
        class_addMethod(cls, NSSelectorFromString(selectorName), implementation, types);
}

Class WAGRInstallWADebugABPropertiesTableViewController(NSString **diagnostic) {
    static dispatch_once_t once;
    static NSString *resultDiagnostic = nil;
    dispatch_once(&once, ^{
        Class existing = NSClassFromString(kWAGRABPropsControllerName);
        if (existing) {
            gWAGRABPropsNativeBaseClass = class_getSuperclass(existing);
            resultDiagnostic = [NSString stringWithFormat:@"using loaded %@ superclass=%@",
                kWAGRABPropsControllerName,
                NSStringFromClass(gWAGRABPropsNativeBaseClass) ?: @"nil"];
            return;
        }

        Class base = NSClassFromString(@"WAStaticTableViewController");
        if (!base || !WAGRABPropsMethodMatches(base,
                NSSelectorFromString(@"initWithInsetGrouped"), 2, '@')) {
            resultDiagnostic = @"WAStaticTableViewController.initWithInsetGrouped ABI unavailable";
            return;
        }
        Class cls = objc_allocateClassPair(base, kWAGRABPropsControllerName.UTF8String, 0);
        if (!cls) {
            resultDiagnostic = @"objc_allocateClassPair failed";
            return;
        }
        gWAGRABPropsNativeBaseClass = base;

        BOOL complete = YES;
        complete &= WAGRABPropsAddMethod(cls, @"initWithInsetGroupedAndUserContext:",
            (IMP)WAGRABPropsInitWithInsetGroupedAndUserContext, "@24@0:8@16");
        complete &= WAGRABPropsAddMethod(cls, @"initWithUserContext:",
            (IMP)WAGRABPropsInitWithUserContext, "@24@0:8@16");
        complete &= WAGRABPropsAddMethod(cls, @"userContext",
            (IMP)WAGRABPropsUserContext, "@16@0:8");
        complete &= WAGRABPropsAddMethod(cls, @"abProperties",
            (IMP)WAGRABPropsABProperties, "@16@0:8");
        complete &= WAGRABPropsAddMethod(cls, @"setUpTableView",
            (IMP)WAGRABPropsSetUpTableView, "v16@0:8");
        complete &= WAGRABPropsAddMethod(cls, @"viewDidLoad",
            (IMP)WAGRABPropsViewDidLoad, "v16@0:8");
        complete &= WAGRABPropsAddMethod(cls, @"tableView:willDisplayCell:forRowAtIndexPath:",
            (IMP)WAGRABPropsWillDisplayCell, "v40@0:8@16@24@32");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:updateResultsForSearchString:",
            (IMP)WAGRABPropsSearchUpdate, "v32@0:8@16@24");
        complete &= WAGRABPropsAddMethod(cls, @"numberOfSectionsInSearchController:",
            (IMP)WAGRABPropsSearchSectionCount, "q24@0:8@16");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:numberOfRowsInSection:",
            (IMP)WAGRABPropsSearchRowCount, "q32@0:8@16q24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:cellForRowAtIndexPath:",
            (IMP)WAGRABPropsSearchCell, "@32@0:8@16@24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:didSelectRowAtIndexPath:",
            (IMP)WAGRABPropsSearchSelect, "v32@0:8@16@24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:titleForHeaderInSection:",
            (IMP)WAGRABPropsSearchHeader, "@32@0:8@16q24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:canEditRowAtIndexPath:",
            (IMP)WAGRABPropsSearchCanEdit, "B32@0:8@16@24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:editingStyleForRowAtIndexPath:",
            (IMP)WAGRABPropsSearchEditingStyle, "q32@0:8@16@24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:heightForHeaderInSection:",
            (IMP)WAGRABPropsSearchHeaderHeight, "d32@0:8@16q24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:heightForFooterInSection:",
            (IMP)WAGRABPropsSearchHeaderHeight, "d32@0:8@16q24");
        complete &= WAGRABPropsAddMethod(cls, @"searchController:viewForHeaderInSection:",
            (IMP)WAGRABPropsSearchHeaderView, "@32@0:8@16q24");
        complete &= WAGRABPropsAddMethod(cls, @"searchControllerShouldShowResultsForEmptySearchString:",
            (IMP)WAGRABPropsSearchEmpty, "B24@0:8@16");
        complete &= WAGRABPropsAddMethod(cls, @"searchControllerWillBeginSearch:",
            (IMP)WAGRABPropsNoOp, "v24@0:8@16");
        complete &= WAGRABPropsAddMethod(cls, @"searchControllerDidEndSearch:",
            (IMP)WAGRABPropsNoOp, "v24@0:8@16");

        Protocol *searchProtocol = objc_getProtocol("WASearchControllerDelegate");
        if (searchProtocol) class_addProtocol(cls, searchProtocol);
        if (!complete) {
            objc_disposeClassPair(cls);
            gWAGRABPropsNativeBaseClass = Nil;
            resultDiagnostic = @"one or more native controller methods could not be registered";
            return;
        }
        objc_registerClassPair(cls);
        resultDiagnostic = [NSString stringWithFormat:
            @"registered %@ : %@ with WATableSection/WATableRow + WASearchControllerDelegate",
            kWAGRABPropsControllerName, NSStringFromClass(base)];
    });

    Class result = NSClassFromString(kWAGRABPropsControllerName);
    if (diagnostic) *diagnostic = resultDiagnostic ?: @"registration not attempted";
    WAGRLogAppendF(@"[WADebugABProperties] %@", resultDiagnostic ?: @"unknown registration state");
    return result;
}

UIViewController *WAGRCreateWADebugABPropertiesTableViewController(
    id userContext, id abProperties, NSString **diagnostic) {
    NSString *installDiagnostic = nil;
    Class cls = WAGRInstallWADebugABPropertiesTableViewController(&installDiagnostic);
    if (!cls) {
        if (diagnostic) *diagnostic = installDiagnostic;
        return nil;
    }
    SEL initializer = NSSelectorFromString(@"initWithInsetGroupedAndUserContext:");
    if (!WAGRABPropsMethodEncodingMatches(cls, initializer, "@24@0:8@16")) {
        if (diagnostic) *diagnostic = @"registered controller initializer ABI mismatch";
        return nil;
    }
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    id controller = ((id (*)(id, SEL, id))objc_msgSend)(allocated,
                                                        initializer, userContext);
    if (![controller isKindOfClass:UIViewController.class]) {
        if (diagnostic) *diagnostic = @"registered controller did not initialize as UIViewController";
        return nil;
    }
    WAGRRecreatedABPropsState *state = WAGRABPropsState(controller, YES);
    state.userContext = userContext;
    state.abProperties = abProperties;
    if (diagnostic) *diagnostic = [NSString stringWithFormat:@"%@; context=%@ abProperties=%@",
        installDiagnostic ?: @"installed", NSStringFromClass([userContext class]),
        NSStringFromClass([abProperties class])];
    return controller;
}
