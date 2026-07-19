// WAGRDebugMenuInstrumentation.xm
//
// Keeps WADebugViewController as the native owner of the AB Props section.
// Release-candidate builds replace that section with a warning row. We remove
// only the warning row and add one native-first entry. Controller/factory
// discovery and the expensive Objective-C class scan happen only after the
// user taps AB Props. The typed runtime browser is an explicit last fallback.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Menu/WAGRABPropsBrowserVC.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRNativeABPropsResolver.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRLog.h"

extern "C" void WAGRDogfoodKnownWAABEnsureInstalled(void);

@interface WACachedCopyMutableArray : NSObject
- (NSArray *)immutableArray;
@end

@interface WATableRow : NSObject
- (UITableViewCell *)cell;
- (void)setHandler:(void (^)(void))handler;
@end

@interface WATableSection : NSObject
- (id)rows;
- (void)deleteRow:(WATableRow *)row;
- (WATableRow *)addTableRowWithCellStyle:(UITableViewCellStyle)style;
- (NSString *)headerText;
@end

@interface WADebugViewController : UIViewController
- (void)createSections;
- (id)sections;
- (id)userContext;
@end

typedef void (*WAGRVoidIMP)(id, SEL);
typedef void (*WAGRVoidBoolIMP)(id, SEL, BOOL);

static WAGRVoidIMP orig_WADebugCreateSections = NULL;
static WAGRVoidIMP orig_WADebugViewDidLoad = NULL;
static WAGRVoidBoolIMP orig_WADebugViewDidAppear = NULL;
static BOOL gWAGRDebugCreateSectionsHooked = NO;
static BOOL gWAGRDebugViewDidLoadHooked = NO;
static BOOL gWAGRDebugViewDidAppearHooked = NO;
static NSUInteger gWAGRABPropsEntryInstallCount = 0;
static NSUInteger gWAGRABPropsNativeOpenCount = 0;
static NSUInteger gWAGRABPropsFallbackOpenCount = 0;
static NSString * const kWAGRNativeABPropsEntryIdentifier =
    @"watweaks.native.abprops.entry";

static BOOL WAGRMethodIsVoidWithArguments(Method method,
                                           unsigned int argumentCount) {
    if (!method || method_getNumberOfArguments(method) != argumentCount) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'v';
}

static NSArray *WAGRSnapshotCollection(id collection) {
    if (!collection) return @[];
    if ([collection respondsToSelector:@selector(immutableArray)]) {
        id snapshot = [collection immutableArray];
        return [snapshot isKindOfClass:NSArray.class] ? snapshot : @[];
    }
    if ([collection isKindOfClass:NSArray.class]) return [collection copy];
    NSMutableArray *snapshot = [NSMutableArray array];
    if ([collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
        for (id object in collection) {
            if (object) [snapshot addObject:object];
        }
    }
    return snapshot;
}

static NSString *WAGRRowText(WATableRow *row) {
    UITableViewCell *cell = [row cell];
    return [NSString stringWithFormat:@"%@ %@",
        cell.textLabel.text ?: @"", cell.detailTextLabel.text ?: @""];
}

static BOOL WAGRRowIsRCWarning(WATableRow *row) {
    NSString *text = WAGRRowText(row).lowercaseString;
    return [text containsString:@"ab props are not available"] ||
           [text containsString:@"release candidate builds"];
}

static BOOL WAGRSectionContainsRCWarning(WATableSection *section) {
    for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
        if (WAGRRowIsRCWarning(row)) return YES;
    }
    return NO;
}

static BOOL WAGRSectionContainsInjectedEntry(WATableSection *section) {
    for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
        UITableViewCell *cell = [row cell];
        if ([cell.accessibilityIdentifier
                isEqualToString:kWAGRNativeABPropsEntryIdentifier]) return YES;
    }
    return NO;
}

static BOOL WAGRSectionHasNativeContent(WATableSection *section) {
    for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
        if (WAGRRowIsRCWarning(row)) continue;
        UITableViewCell *cell = [row cell];
        if ([cell.accessibilityIdentifier
                isEqualToString:kWAGRNativeABPropsEntryIdentifier]) continue;
        NSString *text = WAGRRowText(row);
        if ([text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return YES;
    }
    return NO;
}

static WATableSection *WAGRFindABPropsSection(WADebugViewController *controller) {
    if (!controller || ![controller respondsToSelector:@selector(sections)]) return nil;
    id sections = nil;
    @try {
        sections = [controller sections];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }

    for (id candidate in WAGRSnapshotCollection(sections)) {
        if (![candidate respondsToSelector:@selector(headerText)]) continue;
        NSString *header = nil;
        @try {
            header = [candidate headerText];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if ((header.length &&
             [header caseInsensitiveCompare:@"AB Props"] == NSOrderedSame) ||
            WAGRSectionContainsRCWarning(candidate)) {
            return candidate;
        }
    }
    return nil;
}

static id WAGRDebugUserContext(WADebugViewController *controller) {
    if (!controller || ![controller respondsToSelector:@selector(userContext)]) return nil;
    @try {
        return [controller userContext];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void WAGRPresentController(UIViewController *host,
                                  UIViewController *controller) {
    if (!host || !controller) return;
    UINavigationController *navigation = host.navigationController;
    if (navigation) {
        [navigation pushViewController:controller animated:YES];
        return;
    }
    UINavigationController *wrapper = [[UINavigationController alloc]
        initWithRootViewController:controller];
    wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
    [host presentViewController:wrapper animated:YES completion:nil];
}

static void WAGRPresentRuntimeFallback(WADebugViewController *host,
                                       id userContext,
                                       NSString *nativeDiagnostic) {
    WAGRABPropsBrowserVC *browser = [[WAGRABPropsBrowserVC alloc]
        initWithUserContext:userContext];
    gWAGRABPropsFallbackOpenCount++;
    WAGRLogAppendF(@"[DebugMenu][ABProps] native unavailable; runtime fallback (%@)",
                   nativeDiagnostic ?: @"no diagnostic");
    WAGRPresentController(host, browser);
}

static void WAGROpenABProps(WADebugViewController *host) {
    if (!host) return;
    WAGRDogfoodKnownWAABEnsureInstalled();
    id userContext = WAGRDebugUserContext(host);
    NSString *diagnostic = nil;
    UIViewController *nativeController = WAGRResolveNativeABPropsController(
        host, userContext, &diagnostic);
    if (nativeController) {
        gWAGRABPropsNativeOpenCount++;
        WAGRLogAppendF(@"[DebugMenu][ABProps] opening native controller %@ (%@)",
                       NSStringFromClass([nativeController class]),
                       diagnostic ?: @"resolved");
        WAGRPresentController(host, nativeController);
        return;
    }
    WAGRPresentRuntimeFallback(host, userContext, diagnostic);
}

static WATableRow *WAGRAddNativeABPropsEntry(WATableSection *section,
                                              WADebugViewController *controller) {
    WATableRow *row = [section addTableRowWithCellStyle:UITableViewCellStyleSubtitle];
    if (!row) return nil;
    UITableViewCell *cell = [row cell];
    cell.accessibilityIdentifier = kWAGRNativeABPropsEntryIdentifier;
    cell.textLabel.text = @"AB Props";
    cell.detailTextLabel.text =
        @"Abre o controller/factory nativo carregado nesta sessão; "
         "usa o browser runtime somente como fallback.";
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIImage *image = [UIImage systemImageNamed:@"switch.2"];
    if (image) {
        cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        cell.imageView.tintColor = UIColor.systemGreenColor;
    }

    __weak WADebugViewController *weakController = controller;
    [row setHandler:^{
        WADebugViewController *strongController = weakController;
        if (strongController) WAGROpenABProps(strongController);
    }];
    return row;
}

static BOOL WAGRConfigureABPropsSection(WADebugViewController *controller) {
    if (!controller) return NO;
    WATableSection *section = WAGRFindABPropsSection(controller);
    if (!section) {
        WAGRLogAppend(@"[DebugMenu][ABProps] AB Props section not found yet");
        return NO;
    }
    if (WAGRSectionContainsInjectedEntry(section)) return NO;

    BOOL hasWarning = WAGRSectionContainsRCWarning(section);
    if (!hasWarning && WAGRSectionHasNativeContent(section)) {
        WAGRLogAppend(@"[DebugMenu][ABProps] native section already populated; preserving it");
        return NO;
    }

    @try {
        if (hasWarning) {
            for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
                if (WAGRRowIsRCWarning(row)) [section deleteRow:row];
            }
        }
        if (!WAGRAddNativeABPropsEntry(section, controller)) return NO;
        gWAGRABPropsEntryInstallCount++;
        WAGRLogAppendF(@"[DebugMenu][ABProps] native-first entry installed count=%lu",
                       (unsigned long)gWAGRABPropsEntryInstallCount);
        return YES;
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[DebugMenu][ABProps] section exception %@: %@",
                       exception.name, exception.reason);
        return NO;
    }
}

static void WAGRReloadTablesInView(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:UITableView.class]) [(UITableView *)view reloadData];
    for (UIView *subview in view.subviews) WAGRReloadTablesInView(subview);
}

static void WAGRPatchVisibleDebugController(UIViewController *controller) {
    if (!controller) return;
    Class debugClass = NSClassFromString(@"WADebugViewController");
    if (debugClass && [controller isKindOfClass:debugClass]) {
        if (WAGRConfigureABPropsSection((WADebugViewController *)controller)) {
            WAGRReloadTablesInView(controller.view);
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        WAGRPatchVisibleDebugController(child);
    }
    if (controller.presentedViewController) {
        WAGRPatchVisibleDebugController(controller.presentedViewController);
    }
}

static void WAGRPatchVisibleDebugControllers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            WAGRPatchVisibleDebugController(window.rootViewController);
        }
    });
}

static void hook_WADebugCreateSections(id self, SEL _cmd) {
    if (orig_WADebugCreateSections) orig_WADebugCreateSections(self, _cmd);
    WAGRConfigureABPropsSection((WADebugViewController *)self);
}

static void hook_WADebugViewDidLoad(id self, SEL _cmd) {
    if (orig_WADebugViewDidLoad) orig_WADebugViewDidLoad(self, _cmd);
    if (WAGRConfigureABPropsSection((WADebugViewController *)self)) {
        WAGRReloadTablesInView(((UIViewController *)self).view);
    }
}

static void hook_WADebugViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_WADebugViewDidAppear) orig_WADebugViewDidAppear(self, _cmd, animated);
    if (WAGRConfigureABPropsSection((WADebugViewController *)self)) {
        WAGRReloadTablesInView(((UIViewController *)self).view);
    }
}

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void) {
    if (WAGRPref(kWAGREmployeeMaster)) WAGRDogfoodKnownWAABEnsureInstalled();

    Class cls = NSClassFromString(@"WADebugViewController");
    if (!cls) {
        WAGRLogAppend(@"[DebugMenu][ABProps] WADebugViewController not loaded");
        return;
    }

    if (!gWAGRDebugCreateSectionsHooked) {
        SEL selector = NSSelectorFromString(@"createSections");
        Method method = class_getInstanceMethod(cls, selector);
        if (WAGRMethodIsVoidWithArguments(method, 2)) {
            MSHookMessageEx(cls, selector, (IMP)hook_WADebugCreateSections,
                            (IMP *)&orig_WADebugCreateSections);
            gWAGRDebugCreateSectionsHooked = (orig_WADebugCreateSections != NULL);
        }
    }

    if (!gWAGRDebugViewDidLoadHooked) {
        SEL selector = @selector(viewDidLoad);
        Method method = class_getInstanceMethod(cls, selector);
        if (WAGRMethodIsVoidWithArguments(method, 2)) {
            MSHookMessageEx(cls, selector, (IMP)hook_WADebugViewDidLoad,
                            (IMP *)&orig_WADebugViewDidLoad);
            gWAGRDebugViewDidLoadHooked = (orig_WADebugViewDidLoad != NULL);
        }
    }

    if (!gWAGRDebugViewDidAppearHooked) {
        SEL selector = @selector(viewDidAppear:);
        Method method = class_getInstanceMethod(cls, selector);
        if (WAGRMethodIsVoidWithArguments(method, 3)) {
            MSHookMessageEx(cls, selector, (IMP)hook_WADebugViewDidAppear,
                            (IMP *)&orig_WADebugViewDidAppear);
            gWAGRDebugViewDidAppearHooked = (orig_WADebugViewDidAppear != NULL);
        }
    }

    WAGRLogAppendF(@"[DebugMenu][ABProps] hooks create=%@ load=%@ appear=%@",
        gWAGRDebugCreateSectionsHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidLoadHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidAppearHooked ? @"YES" : @"NO");
    WAGRPatchVisibleDebugControllers();
}

extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    NSDictionary *stats = WAGRABPropsCatalogStats();
    return [NSString stringWithFormat:
        @"AB Props hooks create=%@ load=%@ appear=%@\nentry installs=%lu\nnative opens=%lu\nruntime fallbacks=%lu\nlive selectors=%@\ntyped overrides=%lu\nnative resolver=%@",
        gWAGRDebugCreateSectionsHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidLoadHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidAppearHooked ? @"YES" : @"NO",
        (unsigned long)gWAGRABPropsEntryInstallCount,
        (unsigned long)gWAGRABPropsNativeOpenCount,
        (unsigned long)gWAGRABPropsFallbackOpenCount,
        stats[@"selectors"] ?: @"not scanned yet",
        (unsigned long)WAGRRuntimeValueAllOverrideSpecs().count,
        WAGRNativeABPropsResolverDiagnosticText() ?: @"n/a"];
}

__attribute__((constructor))
static void WAGRDebugMenuInstrumentationCtor(void) {
    @autoreleasepool {
        if (!WAGRPref(kWAGREmployeeMaster) &&
            !WAGRPref(kWAGRInternalMaster) &&
            !WAGRPref(kWAGRDebugMenuNative) &&
            !WAGRPref(kWAGRDebugMode)) return;
        WAGRDebugMenuInstrumentationEnsureInstalled();
    }
}
