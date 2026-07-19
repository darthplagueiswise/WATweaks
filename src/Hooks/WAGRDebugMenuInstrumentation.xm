// WAGRDebugMenuInstrumentation.xm
//
// Capstone confirms that this RC build creates the AB Props unavailable card
// unconditionally inside -[WADebugViewController createSections]. There is no
// employee/debug-build branch to flip in that region. Preserve the native
// Developer controller, then replace only that section with runtime-backed
// actions. Hooks are direct class/selector installs; there is no startup scan.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <string.h>
#import "../WAGramPrefix.h"
#import "../Menu/WAGRABPropsBrowserVC.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "../Runtime/WAGRLog.h"

extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC,
                                                         NSError **outError);

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
- (void)setHeaderText:(NSString *)text;
- (void)setFooterText:(NSString *)text;
@end

@interface WADebugViewController : UIViewController
- (void)createSections;
- (id)sections;
- (id)userContext;
- (void)resetAllOverriddenABProps;
@end

typedef void (*WAGRVoidIMP)(id, SEL);
typedef void (*WAGRVoidBoolIMP)(id, SEL, BOOL);

static WAGRVoidIMP orig_WADebugCreateSections = NULL;
static WAGRVoidIMP orig_WADebugViewDidLoad = NULL;
static WAGRVoidBoolIMP orig_WADebugViewDidAppear = NULL;
static BOOL gWAGRDebugCreateSectionsHooked = NO;
static BOOL gWAGRDebugViewDidLoadHooked = NO;
static BOOL gWAGRDebugViewDidAppearHooked = NO;
static NSUInteger gWAGRABPropsSectionPatchCount = 0;

static BOOL WAGRMethodIsVoidWithArguments(Method method, unsigned int arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
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
        for (id object in collection) if (object) [snapshot addObject:object];
    }
    return snapshot;
}

static NSString *WAGRRowText(WATableRow *row) {
    UITableViewCell *cell = [row cell];
    return [NSString stringWithFormat:@"%@ %@",
        cell.textLabel.text ?: @"", cell.detailTextLabel.text ?: @""];
}

static BOOL WAGRSectionContainsRCWarning(WATableSection *section) {
    for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
        NSString *text = WAGRRowText(row).lowercaseString;
        if ([text containsString:@"ab props are not available"] ||
            [text containsString:@"release candidate builds"]) return YES;
    }
    return NO;
}

static BOOL WAGRSectionAlreadyPatched(WATableSection *section) {
    for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
        NSString *text = WAGRRowText(row).lowercaseString;
        if ([text containsString:@"ab props runtime completo"]) return YES;
    }
    return NO;
}

static WATableSection *WAGRFindABPropsSection(WADebugViewController *controller) {
    if (!controller || ![controller respondsToSelector:@selector(sections)]) return nil;
    id sections = nil;
    @try { sections = [controller sections]; }
    @catch (__unused NSException *exception) { sections = nil; }

    for (id candidate in WAGRSnapshotCollection(sections)) {
        if (![candidate respondsToSelector:@selector(headerText)]) continue;
        NSString *header = nil;
        @try { header = [candidate headerText]; }
        @catch (__unused NSException *exception) { header = nil; }
        if ((header.length && [header caseInsensitiveCompare:@"AB Props"] == NSOrderedSame) ||
            WAGRSectionContainsRCWarning(candidate)) return candidate;
    }
    return nil;
}

static UIViewController *WAGRTopPresenter(UIViewController *controller) {
    UIViewController *top = controller;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) {
        UIViewController *visible = ((UINavigationController *)top).visibleViewController;
        if (visible) top = visible;
    }
    return top;
}

static void WAGRPresentMessage(UIViewController *host,
                               NSString *title,
                               NSString *message) {
    if (!host) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [WAGRTopPresenter(host) presentViewController:alert animated:YES completion:nil];
}

static void WAGRPresentABPropsBrowser(WADebugViewController *host) {
    if (!host) return;
    id userContext = nil;
    @try {
        if ([host respondsToSelector:@selector(userContext)]) userContext = [host userContext];
    } @catch (__unused NSException *exception) { userContext = nil; }

    WAGRABPropsBrowserVC *browser = [[WAGRABPropsBrowserVC alloc]
        initWithUserContext:userContext];
    UINavigationController *navigation = host.navigationController;
    if (navigation) {
        [navigation pushViewController:browser animated:YES];
    } else {
        UINavigationController *wrapper = [[UINavigationController alloc]
            initWithRootViewController:browser];
        wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
        [host presentViewController:wrapper animated:YES completion:nil];
    }
}

static void WAGRAddActionRow(WATableSection *section,
                             NSString *title,
                             NSString *detail,
                             NSString *symbol,
                             UIColor *tint,
                             void (^handler)(void)) {
    WATableRow *row = [section addTableRowWithCellStyle:UITableViewCellStyleSubtitle];
    if (!row) return;
    UITableViewCell *cell = [row cell];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIImage *image = [UIImage systemImageNamed:symbol];
    if (image) {
        cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        cell.imageView.tintColor = tint;
    }
    [row setHandler:[handler copy]];
}

static BOOL WAGRConfigureABPropsSection(WADebugViewController *controller) {
    if (!controller) return NO;
    WATableSection *section = WAGRFindABPropsSection(controller);
    if (!section) {
        WAGRLogAppend(@"[DebugMenu][ABProps] AB Props section not found yet");
        return NO;
    }
    if (WAGRSectionAlreadyPatched(section)) return NO;

    @try {
        for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
            [section deleteRow:row];
        }

        [section setHeaderText:@"AB Props"];
        [section setFooterText:
            @"Descoberto do Objective-C runtime carregado. Classes, selectors, imagens e ABIs são reavaliados ao abrir/atualizar; não depende de catálogo estático."];

        __weak WADebugViewController *weakController = controller;
        WAGRAddActionRow(section,
            @"AB Props Runtime completo",
            @"Enumera WAABProperties e providers vivos desta sessão · busca · valor atual · override tipado",
            @"switch.2", UIColor.systemGreenColor, ^{
                WADebugViewController *strongController = weakController;
                if (strongController) WAGRPresentABPropsBrowser(strongController);
            });

        WAGRAddActionRow(section,
            @"Private Experimentation",
            @"Abre o manager nativo usando o userContext real e seus PrivateABProperties/debug overrides",
            @"testtube.2", UIColor.systemPurpleColor, ^{
                WADebugViewController *strongController = weakController;
                if (!strongController) return;
                NSError *error = nil;
                if (!WAGRLaunchPrivateExperimentationDebug(strongController, &error)) {
                    WAGRPresentMessage(strongController,
                        @"Private Experimentation",
                        error.localizedDescription ?: @"Não foi possível abrir o manager nativo.");
                }
            });

        WAGRAddActionRow(section,
            @"Reinstalar overrides tipados",
            @"Reaplica somente class/selector/ABI persistidos; não executa varredura global",
            @"arrow.triangle.2.circlepath", UIColor.systemCyanColor, ^{
                WADebugViewController *strongController = weakController;
                NSUInteger installed = WAGRRuntimeValueReinstallPersistedHooks();
                WAGRPresentMessage(strongController,
                    @"Overrides tipados",
                    [NSString stringWithFormat:@"%lu hooks reinstalados de %lu overrides persistidos.",
                     (unsigned long)installed,
                     (unsigned long)WAGRRuntimeValueAllOverrideSpecs().count]);
            });

        WAGRAddActionRow(section,
            @"Resetar overrides AB Props",
            @"Limpa overrides tipados da tweak e chama o reset nativo do WADebugViewController",
            @"arrow.counterclockwise", UIColor.systemOrangeColor, ^{
                WADebugViewController *strongController = weakController;
                NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();
                for (NSDictionary *spec in specs) {
                    WAGRRuntimeValueClearOverride(spec[@"class"],
                                                  spec[@"selector"],
                                                  [spec[@"meta"] boolValue]);
                }
                if ([strongController respondsToSelector:@selector(resetAllOverriddenABProps)]) {
                    [strongController resetAllOverriddenABProps];
                }
                WAGRPresentMessage(strongController,
                    @"AB Props",
                    [NSString stringWithFormat:@"%lu overrides tipados removidos.",
                     (unsigned long)specs.count]);
            });

        gWAGRABPropsSectionPatchCount++;
        WAGRLogAppendF(@"[DebugMenu][ABProps] RC warning replaced; patchCount=%lu",
                       (unsigned long)gWAGRABPropsSectionPatchCount);
        return YES;
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[DebugMenu][ABProps] patch exception %@: %@",
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
    if ([controller isKindOfClass:NSClassFromString(@"WADebugViewController")]) {
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
        @"AB Props hooks create=%@ load=%@ appear=%@\nsection patches=%lu\nlive selectors=%@\ntyped overrides=%lu\nWAABProperties=%@\nPrivateABProperties=%@",
        gWAGRDebugCreateSectionsHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidLoadHooked ? @"YES" : @"NO",
        gWAGRDebugViewDidAppearHooked ? @"YES" : @"NO",
        (unsigned long)gWAGRABPropsSectionPatchCount,
        stats[@"selectors"] ?: @"not scanned yet",
        (unsigned long)WAGRRuntimeValueAllOverrideSpecs().count,
        NSClassFromString(@"WAABProperties") ? @"loaded" : @"missing",
        (NSClassFromString(@"_TtC24WAPrivateExperimentation19PrivateABProperties") ||
         NSClassFromString(@"WAPrivateExperimentation.PrivateABProperties")) ? @"loaded" : @"missing"];
}

__attribute__((constructor))
static void WAGRDebugMenuInstrumentationCtor(void) {
    @autoreleasepool {
        // Direct class/selector lookup only. No objc_getClassList, dladdr loop or
        // runtime scan during launch. The actual AB scan remains user-triggered.
        if (!WAGRPref(kWAGREmployeeMaster) &&
            !WAGRPref(kWAGRInternalMaster) &&
            !WAGRPref(kWAGRDebugMenuNative) &&
            !WAGRPref(kWAGRDebugMode)) return;
        WAGRDebugMenuInstrumentationEnsureInstalled();
    }
}
