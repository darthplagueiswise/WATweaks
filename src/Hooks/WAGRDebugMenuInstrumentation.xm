// WAGRDebugMenuInstrumentation.xm
// The RC build hardcodes an unavailable-warning in -createSections even though
// WAABProperties, its categories, PrivateExperimentation and override storage
// remain present. Preserve the native Developer menu and replace only that dead
// section with actions backed by the real runtime objects.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <string.h>
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

typedef void (*WAGRCreateSectionsIMP)(id, SEL);
static WAGRCreateSectionsIMP orig_WADebugCreateSections = NULL;
static BOOL gWAGRDebugCreateSectionsHooked = NO;
static NSUInteger gWAGRABPropsSectionPatchCount = 0;

static BOOL WAGRMethodHasExactEncoding(Method method, const char *expected) {
    if (!method || !expected) return NO;
    const char *actual = method_getTypeEncoding(method);
    return actual && strcmp(actual, expected) == 0;
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

static BOOL WAGRSectionContainsRCWarning(WATableSection *section) {
    for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
        UITableViewCell *cell = [row cell];
        NSString *text = [NSString stringWithFormat:@"%@ %@",
            cell.textLabel.text ?: @"", cell.detailTextLabel.text ?: @""].lowercaseString;
        if ([text containsString:@"ab props are not available"] ||
            [text containsString:@"release candidate builds"]) return YES;
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
            WAGRSectionContainsRCWarning(candidate)) {
            return candidate;
        }
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

static void WAGRConfigureABPropsSection(WADebugViewController *controller) {
    if (!controller) return;
    WATableSection *section = WAGRFindABPropsSection(controller);
    if (!section) {
        WAGRLogAppend(@"[DebugMenu][ABProps] native AB Props warning section not found");
        return;
    }

    @try {
        for (WATableRow *row in WAGRSnapshotCollection([section rows])) {
            [section deleteRow:row];
        }

        [section setHeaderText:@"AB Props"];
        [section setFooterText:
            @"Catálogo regenerado do executable e SharedModules desta build. "
             "Os overrides usam trampolines separados por ABI e podem ser removidos com Usar original."];

        __weak WADebugViewController *weakController = controller;
        WAGRAddActionRow(section,
            @"AB Props Runtime completo",
            @"10.355 selectors editáveis · 7.782 BOOL · 1.797 inteiros · 199 double · 577 objetos",
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
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[DebugMenu][ABProps] section patch exception %@: %@",
                       exception.name, exception.reason);
    }
}

static void hook_WADebugCreateSections(id self, SEL _cmd) {
    if (orig_WADebugCreateSections) orig_WADebugCreateSections(self, _cmd);
    if ([self isKindOfClass:UIViewController.class]) {
        WAGRConfigureABPropsSection((WADebugViewController *)self);
    }
}

extern "C" void WAGRDebugMenuInstrumentationEnsureInstalled(void) {
    if (gWAGRDebugCreateSectionsHooked) return;
    Class cls = NSClassFromString(@"WADebugViewController");
    SEL selector = NSSelectorFromString(@"createSections");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!WAGRMethodHasExactEncoding(method, "v16@0:8")) {
        WAGRLogAppend(@"[DebugMenu][ABProps] createSections unavailable or ABI changed");
        return;
    }

    MSHookMessageEx(cls,
                    selector,
                    (IMP)hook_WADebugCreateSections,
                    (IMP *)&orig_WADebugCreateSections);
    gWAGRDebugCreateSectionsHooked = (orig_WADebugCreateSections != NULL);
    WAGRLogAppendF(@"[DebugMenu][ABProps] createSections hook=%@",
                   gWAGRDebugCreateSectionsHooked ? @"YES" : @"NO");
}

extern "C" NSString *WAGRDebugMenuInstrumentationDiagnosticText(void) {
    NSDictionary *stats = WAGRABPropsCatalogStats();
    return [NSString stringWithFormat:
        @"AB Props createSections hook=%@\nsection patches=%lu\ncatalog supported=%@\ntyped overrides=%lu\nWAABProperties=%@\nPrivateABProperties=%@",
        gWAGRDebugCreateSectionsHooked ? @"YES" : @"NO",
        (unsigned long)gWAGRABPropsSectionPatchCount,
        stats[@"selectors_supported"] ?: @"catalog unavailable",
        (unsigned long)WAGRRuntimeValueAllOverrideSpecs().count,
        NSClassFromString(@"WAABProperties") ? @"loaded" : @"missing",
        (NSClassFromString(@"_TtC24WAPrivateExperimentation19PrivateABProperties") ||
         NSClassFromString(@"WAPrivateExperimentation.PrivateABProperties")) ? @"loaded" : @"missing"];
}
