// WAGRDogfoodMenuPatch.xm
// Keeps the existing settings controller intact while replacing the redundant
// Dogfood rows with the deterministic master, reversible runtime sweep and
// native WhatsApp entry points.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"
#import "WAGRMainSettingsVC.h"

extern "C" NSUInteger WAGREmployeeSweepSetEnabled(BOOL enabled);
extern "C" NSString *WAGREmployeeSweepDiagnosticText(void);
extern "C" NSString *WAGRDogfoodDiagnosticText(void);
extern "C" BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);
extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(UIViewController *fromVC, NSError **outError);

typedef NS_ENUM(NSInteger, WAGRDogfoodPatchedCellType) {
    WAGRDogfoodPatchedCellSwitch = 0,
    WAGRDogfoodPatchedCellNav = 1,
    WAGRDogfoodPatchedCellAction = 2,
    WAGRDogfoodPatchedCellDestructive = 3,
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
        while (presenter.presentedViewController) {
            presenter = presenter.presentedViewController;
        }

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
            style:UIAlertActionStyleCancel
            handler:nil]];
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
           [title isEqualToString:@"isInternalMaster"];
}

%hook WAGRMainSettingsVC

- (void)rebuildSections {
    %orig;

    NSArray<WATSection *> *sections = nil;
    @try {
        sections = [self valueForKey:@"_sections"];
    } @catch (__unused NSException *exception) {
        return;
    }
    if (![sections isKindOfClass:NSArray.class]) return;

    NSMutableArray<WATSection *> *patchedSections = [sections mutableCopy];
    for (NSUInteger sectionIndex = 0; sectionIndex < patchedSections.count; sectionIndex++) {
        WATSection *section = patchedSections[sectionIndex];
        if (![section.header isEqualToString:@"Dogfood / Internal"]) continue;

        NSMutableArray<WATCell *> *rows = [NSMutableArray array];
        for (WATCell *row in section.rows ?: @[]) {
            if (WAGRDogfoodRowIsRedundant(row)) continue;
            if ([row.title isEqualToString:@"★ Employee master"]) {
                row.title = @"Employee / Internal";
                row.subtitle = @"Gate conhecido + Developer Menu + ABProps internos confirmados";
            }
            [rows addObject:row];
        }

        WATCell *sweep = WAGRDogfoodSwitch(
            @"Employee sweep runtime",
            @"Busca pós-launch apenas selectors BOOL allowlisted e persiste os alvos exatos",
            @"scope",
            ^BOOL{
                return WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP);
            },
            ^(BOOL enabled) {
                NSUInteger changed = WAGREmployeeSweepSetEnabled(enabled);
                NSLog(@"[WATweaks][EmployeeSweep] %@ changed=%lu",
                      enabled ? @"enabled" : @"disabled",
                      (unsigned long)changed);
            });

        NSUInteger insertIndex = rows.count > 0 ? 1 : 0;
        [rows insertObject:sweep atIndex:MIN(insertIndex, rows.count)];

        [rows addObject:WAGRDogfoodAction(
            @"Abrir Developer Menu nativo",
            @"Usa DebugMenuProvider.presentDebugControllerIfNeeded; não instancia uma tela falsa",
            @"ladybug.fill",
            ^(UIViewController *from) {
                NSError *error = nil;
                if (!WAGRLaunchNativeDeveloperMenu(from, &error)) {
                    WAGRDogfoodMenuAlert(from,
                        @"Developer Menu",
                        error.localizedDescription ?: @"O opener nativo não ficou disponível.");
                }
            })];

        [rows addObject:WAGRDogfoodAction(
            @"Abrir Private Experimentation",
            @"Reutiliza o userContext real capturado pelo Developer Menu",
            @"testtube.2",
            ^(UIViewController *from) {
                NSError *error = nil;
                if (!WAGRLaunchPrivateExperimentationDebug(from, &error)) {
                    WAGRDogfoodMenuAlert(from,
                        @"Private Experimentation",
                        error.localizedDescription ?: @"Abra o Developer Menu nativo primeiro.");
                }
            })];

        [rows addObject:WAGRDogfoodAction(
            @"Diagnóstico Employee / Dogfood",
            @"Hooks conhecidos, gates gerenciados e sweep desta sessão",
            @"stethoscope",
            ^(UIViewController *from) {
                NSString *message = [NSString stringWithFormat:
                    @"%@\n\n[Sweep]\n%@",
                    WAGRDogfoodDiagnosticText() ?: @"n/a",
                    WAGREmployeeSweepDiagnosticText() ?: @"n/a"];
                WAGRDogfoodMenuAlert(from, @"Employee / Dogfood", message);
            })];

        section.footer = @"Master determinístico: WAServerProperties +isInternalUser, DebugMenuProvider e ABProps confirmados. Sweep separado, pós-launch e reversível.";
        section.rows = rows;
        patchedSections[sectionIndex] = section;
        break;
    }

    @try {
        [self setValue:patchedSections forKey:@"_sections"];
    } @catch (__unused NSException *exception) {
    }
}

%end
