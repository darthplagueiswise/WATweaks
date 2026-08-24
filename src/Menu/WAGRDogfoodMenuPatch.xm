// WAGRDogfoodMenuPatch.xm
// Patches the existing settings model without stale runtime surface IDs.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"
#import "WAGRMainSettingsVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "../Runtime/WAGRSurface.h"

extern "C" NSUInteger WAGREmployeeSweepSetEnabled(BOOL enabled);
extern "C" NSString *WAGREmployeeSweepDiagnosticText(void);
extern "C" NSString *WAGRDogfoodDiagnosticText(void);
extern "C" BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC,
                                                NSError **outError);
extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC,
                                                        NSError **outError);

typedef NS_ENUM(NSInteger, WAGRDogfoodPatchedCellType) {
    WAGRDogfoodPatchedCellSwitch = 0,
    WAGRDogfoodPatchedCellNav = 1,
    WAGRDogfoodPatchedCellAction = 2,
    WAGRDogfoodPatchedCellDestructive = 3,
};

typedef NS_ENUM(NSInteger, WAGRRuntimeImageKind) {
    WAGRRuntimeImageKindExecutable = 0,
    WAGRRuntimeImageKindSharedModules = 1,
};

@interface WATCell : NSObject
@property(nonatomic) NSInteger type;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *subtitle;
@property(nonatomic,copy) NSString *icon;
@property(nonatomic,copy) BOOL (^getValue)(void);
@property(nonatomic,copy) void (^onToggle)(BOOL);
@property(nonatomic,copy) void (^onTap)(UIViewController *);
@end

@interface WATSection : NSObject
@property(nonatomic,copy) NSString *header;
@property(nonatomic,copy) NSString *footer;
@property(nonatomic,copy) NSArray<WATCell *> *rows;
@end

@interface WAGRMainSettingsVC (WAGRDogfoodMenuPatchPrivate)
- (void)rebuildSections;
@end

static void WAGRDogfoodMenuAlert(UIViewController *from,
                                  NSString *title,
                                  NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = from;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title ?: @"Dogfood"
            message:message ?: @""
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                UIPasteboard.generalPasteboard.string = message ?: @"";
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static WATCell *WAGRDogfoodSwitch(NSString *title,
                                   NSString *subtitle,
                                   NSString *icon,
                                   BOOL (^getter)(void),
                                   void (^setter)(BOOL)) {
    WATCell *cell = [WATCell new];
    cell.type = WAGRDogfoodPatchedCellSwitch;
    cell.title = title;
    cell.subtitle = subtitle;
    cell.icon = icon;
    cell.getValue = getter;
    cell.onToggle = setter;
    return cell;
}

static WATCell *WAGRDogfoodNav(NSString *title,
                                NSString *subtitle,
                                NSString *icon,
                                void (^handler)(UIViewController *)) {
    WATCell *cell = [WATCell new];
    cell.type = WAGRDogfoodPatchedCellNav;
    cell.title = title;
    cell.subtitle = subtitle;
    cell.icon = icon;
    cell.onTap = handler;
    return cell;
}

static WATCell *WAGRDogfoodAction(NSString *title,
                                   NSString *subtitle,
                                   NSString *icon,
                                   void (^handler)(UIViewController *)) {
    WATCell *cell = [WATCell new];
    cell.type = WAGRDogfoodPatchedCellAction;
    cell.title = title;
    cell.subtitle = subtitle;
    cell.icon = icon;
    cell.onTap = handler;
    return cell;
}

static BOOL WAGRDogfoodRowIsRedundant(WATCell *cell) {
    NSString *title = cell.title ?: @"";
    return [title isEqualToString:@"isInternalUser"] ||
           [title isEqualToString:@"isMetaEmployeeOrInternalTester"] ||
           [title isEqualToString:@"isInternalMaster"] ||
           [title isEqualToString:@"Force Debug Build (reinício)"];
}

static BOOL WAGRRuntimePathIsExecutable(NSString *path) {
    if (!path.length) return NO;
    BOOL framework = [path rangeOfString:@".framework/"
                                 options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL executable = [path hasSuffix:@"/WhatsApp"] ||
                      [path isEqualToString:@"WhatsApp"] ||
                      [path rangeOfString:@"/WhatsApp.app/WhatsApp"
                                  options:NSCaseInsensitiveSearch].location != NSNotFound;
    return executable && !framework;
}

static BOOL WAGRRuntimePathIsSharedModules(NSString *path) {
    if (!path.length) return NO;
    return [path rangeOfString:@"SharedModules.framework/SharedModules"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static WAGRSurfaceSpec *WAGRRuntimeSurfaceForKind(WAGRRuntimeImageKind kind) {
    for (WAGRSurfaceSpec *surface in [WAGRScanner runtimeImageSurfaces]) {
        NSString *path = surface.runtimeImagePath ?: @"";
        if (kind == WAGRRuntimeImageKindExecutable && WAGRRuntimePathIsExecutable(path)) return surface;
        if (kind == WAGRRuntimeImageKindSharedModules && WAGRRuntimePathIsSharedModules(path)) return surface;
    }
    return nil;
}

static NSString *WAGRRuntimeAvailableImages(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (WAGRSurfaceSpec *surface in [WAGRScanner runtimeImageSurfaces]) {
        [lines addObject:[NSString stringWithFormat:@"%@\n%@",
            surface.title ?: @"Runtime", surface.runtimeImagePath ?: @"sem path"]];
    }
    return lines.count ? [lines componentsJoinedByString:@"\n\n"]
                       : @"Nenhuma imagem com getters tipados foi descoberta agora.";
}

static void WAGROpenRuntimeImage(UIViewController *from,
                                 WAGRRuntimeImageKind kind) {
    WAGRSurfaceSpec *surface = WAGRRuntimeSurfaceForKind(kind);
    if (!surface) {
        NSString *wanted = kind == WAGRRuntimeImageKindExecutable ? @"WhatsApp" : @"SharedModules";
        WAGRDogfoodMenuAlert(from, @"Runtime",
            [NSString stringWithFormat:@"Imagem %@ não encontrada no snapshot atual.\n\nImagens descobertas:\n%@",
                wanted, WAGRRuntimeAvailableImages()]);
        return;
    }
    [from.navigationController pushViewController:
        [[WAGRSurfaceBrowserVC alloc] initWithSpec:surface] animated:YES];
}

%hook WAGRMainSettingsVC

- (void)rebuildSections {
    %orig;

    NSArray<WATSection *> *sections = nil;
    @try { sections = [self valueForKey:@"_sections"]; }
    @catch (__unused NSException *exception) { return; }
    if (![sections isKindOfClass:NSArray.class]) return;

    NSMutableArray<WATSection *> *patchedSections = [sections mutableCopy];
    for (NSUInteger sectionIndex = 0; sectionIndex < patchedSections.count; sectionIndex++) {
        WATSection *section = patchedSections[sectionIndex];

        if ([section.header isEqualToString:@"Dogfood / Internal"]) {
            NSMutableArray<WATCell *> *rows = [NSMutableArray array];
            for (WATCell *row in section.rows ?: @[]) {
                if (WAGRDogfoodRowIsRedundant(row)) continue;
                if ([row.title isEqualToString:@"★ Employee master"] ||
                    [row.title isEqualToString:@"Employee / Internal"]) {
                    row.title = @"Employee / Internal / Dogfood";
                    row.subtitle = nil;
                }
                [rows addObject:row];
            }

            WATCell *sweep = WAGRDogfoodSwitch(
                @"Employee runtime sweep", nil, @"scope",
                ^BOOL{ return WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP); },
                ^(BOOL enabled) {
                    NSUInteger changed = WAGREmployeeSweepSetEnabled(enabled);
                    NSLog(@"[WATweaks][EmployeeSweep] %@ changed=%lu",
                          enabled ? @"enabled" : @"disabled", (unsigned long)changed);
                });

            NSUInteger insertIndex = rows.count > 0 ? 1 : 0;
            [rows insertObject:sweep atIndex:MIN(insertIndex, rows.count)];

            [rows addObject:WAGRDogfoodAction(
                @"Developer Menu", nil, @"ladybug",
                ^(UIViewController *from) {
                    NSError *error = nil;
                    if (!WAGRLaunchNativeDeveloperMenu(from, &error)) {
                        WAGRDogfoodMenuAlert(from, @"Developer Menu",
                            error.localizedDescription ?: @"O opener nativo não ficou disponível.");
                    }
                })];

            [rows addObject:WAGRDogfoodAction(
                @"Private Experimentation", nil, @"testtube.2",
                ^(UIViewController *from) {
                    NSError *error = nil;
                    if (!WAGRLaunchPrivateExperimentationDebug(from, &error)) {
                        WAGRDogfoodMenuAlert(from, @"Private Experimentation",
                            error.localizedDescription ?: @"Abra o Developer Menu nativo primeiro.");
                    }
                })];

            [rows addObject:WAGRDogfoodAction(
                @"Diagnóstico Employee / Dogfood", nil, @"stethoscope",
                ^(UIViewController *from) {
                    NSString *message = [NSString stringWithFormat:@"%@\n\n[Sweep]\n%@",
                        WAGRDogfoodDiagnosticText() ?: @"n/a",
                        WAGREmployeeSweepDiagnosticText() ?: @"n/a"];
                    WAGRDogfoodMenuAlert(from, @"Employee / Internal / Dogfood", message);
                })];

            section.footer = nil;
            section.rows = rows;
            patchedSections[sectionIndex] = section;
            continue;
        }

        if ([section.header isEqualToString:@"Runtime Gates"]) {
            section.footer = nil;
            section.rows = @[
                WAGRDogfoodNav(
                    @"Runtime em tempo real", nil, @"waveform.path.ecg",
                    ^(UIViewController *from) {
                        [from.navigationController pushViewController:[WAGRRuntimeGatesVC new] animated:YES];
                    }),
                WAGRDogfoodNav(
                    @"WhatsApp", nil, @"app.dashed",
                    ^(UIViewController *from) {
                        WAGROpenRuntimeImage(from, WAGRRuntimeImageKindExecutable);
                    }),
                WAGRDogfoodNav(
                    @"SharedModules", nil, @"shippingbox",
                    ^(UIViewController *from) {
                        WAGROpenRuntimeImage(from, WAGRRuntimeImageKindSharedModules);
                    }),
            ];
            patchedSections[sectionIndex] = section;
        }
    }

    @try { [self setValue:patchedSections forKey:@"_sections"]; }
    @catch (__unused NSException *exception) {}
}

%end
