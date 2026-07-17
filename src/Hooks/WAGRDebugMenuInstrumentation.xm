// WAGRDebugMenuInstrumentation.xm
// Restores an AB Props browser inside WhatsApp's native Developer menu on
// release-candidate builds. In this build WADebugViewController -createSections
// unconditionally creates a warning card, while WAABProperties still exposes
// thousands of real typed getters through Objective-C categories.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <string.h>
#import "../Menu/WAGRABPropsBrowserVC.h"
#import "../Runtime/WAGRLog.h"

@interface WATableRow : NSObject
- (UITableViewCell *)cell;
- (void)setHandler:(void (^)(void))handler;
@end

@interface WATableSection : NSObject
- (NSArray *)rows;
- (void)deleteRow:(WATableRow *)row;
- (WATableRow *)addTableRowWithCellStyle:(UITableViewCellStyle)style;
- (NSString *)headerText;
- (void)setHeaderText:(NSString *)text;
- (void)setFooterText:(NSString *)text;
@end

@interface WADebugViewController : UIViewController
- (void)createSections;
- (NSArray *)sections;
- (WATableSection *)addSection;
- (WATableSection *)addSectionAtIndex:(NSInteger)index;
- (id)userContext;
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

static WATableSection *WAGRFindABPropsSection(WADebugViewController *controller) {
    if (!controller || ![controller respondsToSelector:@selector(sections)]) return nil;

    NSArray *sections = nil;
    @try {
        sections = [controller sections];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }

    for (id candidate in sections ?: @[]) {
        if (![candidate respondsToSelector:@selector(headerText)]) continue;
        NSString *header = nil;
        @try {
            header = [candidate headerText];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (header.length && [header caseInsensitiveCompare:@"AB Props"] == NSOrderedSame) {
            return (WATableSection *)candidate;
        }
    }
    return nil;
}

static void WAGRPresentABPropsBrowser(WADebugViewController *host) {
    if (!host) return;

    id userContext = nil;
    @try {
        if ([host respondsToSelector:@selector(userContext)]) {
            userContext = [host userContext];
        }
    } @catch (__unused NSException *exception) {
        userContext = nil;
    }

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

static void WAGRConfigureABPropsSection(WADebugViewController *controller) {
    if (!controller) return;

    WATableSection *section = WAGRFindABPropsSection(controller);
    if (!section) {
        @try {
            if ([controller respondsToSelector:@selector(addSectionAtIndex:)]) {
                section = [controller addSectionAtIndex:0];
            } else if ([controller respondsToSelector:@selector(addSection)]) {
                section = [controller addSection];
            }
        } @catch (__unused NSException *exception) {
            section = nil;
        }
    }
    if (!section) {
        WAGRLogAppend(@"[DebugMenu][ABProps] could not resolve/create AB Props section");
        return;
    }

    @try {
        NSArray *existingRows = [[section rows] copy];
        for (WATableRow *row in existingRows ?: @[]) {
            if ([section respondsToSelector:@selector(deleteRow:)]) {
                [section deleteRow:row];
            }
        }

        [section setHeaderText:@"AB Props"];
        [section setFooterText:
            @"A build RC removeu somente o browser nativo. Este browser enumera "
             "os getters reais carregados em WAABProperties/PrivateABProperties. "
             "BOOL, inteiros, float/double e objetos Foundation aceitam override "
             "com trampoline específico para cada ABI."];

        WATableRow *row = [section addTableRowWithCellStyle:UITableViewCellStyleSubtitle];
        UITableViewCell *cell = [row cell];
        cell.textLabel.text = @"Abrir AB Props Runtime";
        cell.detailTextLabel.text = @"Flags reais desta build · busca · valor atual · editor tipado · usar original";
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;

        __weak WADebugViewController *weakController = controller;
        [row setHandler:^{
            WADebugViewController *strongController = weakController;
            if (strongController) WAGRPresentABPropsBrowser(strongController);
        }];

        gWAGRABPropsSectionPatchCount++;
        WAGRLogAppendF(@"[DebugMenu][ABProps] native RC warning replaced; patchCount=%lu",
                       (unsigned long)gWAGRABPropsSectionPatchCount);
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[DebugMenu][ABProps] section patch exception %@: %@",
                       exception.name,
                       exception.reason);
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
        WAGRLogAppend(@"[DebugMenu][ABProps] WADebugViewController -createSections unavailable or ABI changed");
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
    return [NSString stringWithFormat:
        @"AB Props typed browser hook=%@\nsection patches=%lu\nWADebugViewController=%@",
        gWAGRDebugCreateSectionsHooked ? @"YES" : @"NO",
        (unsigned long)gWAGRABPropsSectionPatchCount,
        NSClassFromString(@"WADebugViewController") ? @"loaded" : @"missing"];
}
