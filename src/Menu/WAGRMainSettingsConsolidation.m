#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "WAGRABPropsCuratedVC.h"
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

extern void WAGRNativeDevMenuEnsureHooksInstalled(void);

static void (*gWAGRMainOriginalRebuild)(id, SEL) = NULL;
static void (*gWAGRMainOriginalApply)(id, SEL) = NULL;

static id WAGRMainKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRMainSetKVC(id object, NSString *key, id value) {
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static id WAGRMainNewCell(NSInteger type,
                          NSString *title,
                          NSString *subtitle,
                          NSString *icon,
                          BOOL (^getValue)(void),
                          void (^onToggle)(BOOL),
                          void (^onTap)(UIViewController *)) {
    Class cls = NSClassFromString(@"WATCell");
    id cell = cls ? [cls new] : nil;
    if (!cell) return nil;
    WAGRMainSetKVC(cell, @"type", @(type));
    WAGRMainSetKVC(cell, @"title", title ?: @"");
    WAGRMainSetKVC(cell, @"subtitle", subtitle ?: @"");
    WAGRMainSetKVC(cell, @"icon", icon ?: @"");
    if (getValue) WAGRMainSetKVC(cell, @"getValue", [getValue copy]);
    if (onToggle) WAGRMainSetKVC(cell, @"onToggle", [onToggle copy]);
    if (onTap) WAGRMainSetKVC(cell, @"onTap", [onTap copy]);
    return cell;
}

static id WAGRMainNewSection(NSString *header, NSArray *rows) {
    Class cls = NSClassFromString(@"WATSection");
    id section = cls ? [cls new] : nil;
    if (!section) return nil;
    WAGRMainSetKVC(section, @"header", header ?: @"");
    WAGRMainSetKVC(section, @"rows", rows ?: @[]);
    return section;
}

static void WAGRMainPushCurated(UIViewController *from, WAGRABCuratedMode mode) {
    WAGRABPropsCuratedVC *controller = [[WAGRABPropsCuratedVC alloc] initWithMode:mode];
    [from.navigationController pushViewController:controller animated:YES];
}

static id WAGRMainFeaturesSection(void) {
    id employee = WAGRMainNewCell(1,
        @"Employee / Internal / Dogfood",
        @"ABProps reais do build · mesmos overrides do ABProps Browser",
        @"person.badge.shield.checkmark.fill", nil, nil,
        ^(UIViewController *from){ WAGRMainPushCurated(from, WAGRABCuratedModeEmployeeInternalDogfood); });
    id aura = WAGRMainNewCell(1,
        @"Aura",
        @"Todas as ABProps Aura encontradas no runtime atual",
        @"crown.fill", nil, nil,
        ^(UIViewController *from){ WAGRMainPushCurated(from, WAGRABCuratedModeAura); });
    id liquid = WAGRMainNewCell(1,
        @"Liquid Glass",
        @"Todas as ABProps Liquid Glass encontradas no runtime atual",
        @"sparkles", nil, nil,
        ^(UIViewController *from){ WAGRMainPushCurated(from, WAGRABCuratedModeLiquidGlass); });
    id debug = WAGRMainNewCell(0,
        @"Debug menu nativo",
        @"Hook semântico WATweaks; não duplica nenhuma ABProp individual",
        @"ladybug.fill",
        ^BOOL{ return [[NSUserDefaults standardUserDefaults] boolForKey:kWAGRDebugMenuNative]; },
        ^(BOOL on){
            [[NSUserDefaults standardUserDefaults] setBool:on forKey:kWAGRDebugMenuNative];
            [[NSUserDefaults standardUserDefaults] synchronize];
            WAGRNativeDevMenuEnsureHooksInstalled();
        }, nil);
    NSMutableArray *rows = [NSMutableArray array];
    for (id row in @[employee ?: NSNull.null, aura ?: NSNull.null,
                     liquid ?: NSNull.null, debug ?: NSNull.null]) {
        if (row != NSNull.null) [rows addObject:row];
    }
    return WAGRMainNewSection(@"Features / Experimentos", rows);
}

static void WAGRMainConsolidatedRebuild(id self, SEL _cmd) {
    if (gWAGRMainOriginalRebuild) gWAGRMainOriginalRebuild(self, _cmd);
    NSArray *original = WAGRMainKVC(self, @"sections") ?: @[];
    NSMutableArray *result = [NSMutableArray array];
    id features = WAGRMainFeaturesSection();
    if (features) [result addObject:features];

    // Drop the old parallel storages/masters. Keep ABProps, Runtime and Tools
    // exactly as they existed in the stable 8150 base.
    for (id section in original) {
        NSString *header = WAGRMainKVC(section, @"header");
        if ([header isEqualToString:@"WAABProperties"] ||
            [header isEqualToString:@"Runtime Gates"] ||
            [header isEqualToString:@"Ferramentas"]) {
            [result addObject:section];
        }
    }
    WAGRMainSetKVC(self, @"sections", result);
}

static void WAGRMainConsolidatedApply(id self, SEL _cmd) {
    // RuntimeValueStore is the source of truth for full AB browser + curated
    // feature pages. Reinstall it explicitly before the legacy Apply pipeline.
    (void)WAGRRuntimeValueReinstallPersistedHooks();
    if (gWAGRMainOriginalApply) gWAGRMainOriginalApply(self, _cmd);
}

static void WAGRMainConsolidationInstall(void) {
    Class cls = NSClassFromString(@"WAGRMainSettingsVC");
    if (!cls) return;
    SEL rebuildSel = NSSelectorFromString(@"rebuildSections");
    Method rebuild = class_getInstanceMethod(cls, rebuildSel);
    if (rebuild && method_getImplementation(rebuild) != (IMP)WAGRMainConsolidatedRebuild) {
        gWAGRMainOriginalRebuild = (void (*)(id, SEL))method_getImplementation(rebuild);
        method_setImplementation(rebuild, (IMP)WAGRMainConsolidatedRebuild);
    }
    SEL applySel = NSSelectorFromString(@"applyAllHooks");
    Method apply = class_getInstanceMethod(cls, applySel);
    if (apply && method_getImplementation(apply) != (IMP)WAGRMainConsolidatedApply) {
        gWAGRMainOriginalApply = (void (*)(id, SEL))method_getImplementation(apply);
        method_setImplementation(apply, (IMP)WAGRMainConsolidatedApply);
    }
}

__attribute__((constructor))
static void WAGRMainConsolidationCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRMainConsolidationInstall(); });
    }
}
