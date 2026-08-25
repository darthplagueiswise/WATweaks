#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

static const void *kWAGRCuratedConsistencyEntryKey = &kWAGRCuratedConsistencyEntryKey;

static id WAGRCuratedConsistencyKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRCuratedConsistencyRowSwitch(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    // WAGRABPropsCuratedVC stores its entry under a private associated key. Since
    // associated-object keys are pointer identities, recover the row by locating
    // the switch in the visible cell instead of depending on that private key.
    CGPoint point = [sender convertPoint:CGPointMake(CGRectGetMidX(sender.bounds), CGRectGetMidY(sender.bounds))
                                   toView:((UITableViewController *)self).tableView];
    NSIndexPath *indexPath = [((UITableViewController *)self).tableView indexPathForRowAtPoint:point];
    SEL entrySelector = NSSelectorFromString(@"entryAtIndexPath:");
    WAGRABPropEntry *entry = (indexPath && [self respondsToSelector:entrySelector])
        ? ((id (*)(id, SEL, id))objc_msgSend)(self, entrySelector, indexPath) : nil;
    if (!entry) return;

    BOOL requested = sender.isOn;
    WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                entry.classMethod, entry.typeCode, @(requested));
    BOOL installed = WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                                  entry.classMethod, entry.typeCode);
    if (!installed) {
        // Same contract as the full ABProps Browser at the 8150 base: a toggle is
        // only shown/persisted as an override when the exact ABI hook installed.
        WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.classMethod);
        NSArray *objects = WAGRCuratedConsistencyKVC(self, @"runtimeObjects") ?: @[];
        id raw = nil;
        (void)WAGRABPropsCurrentValue(entry, objects, &raw);
        sender.on = [raw respondsToSelector:@selector(boolValue)] && [raw boolValue];
    }
    [((UITableViewController *)self).tableView reloadData];
}

static void WAGRCuratedConsistencyMaster(id self, SEL _cmd, UISwitch *sender) {
    (void)_cmd;
    NSArray<WAGRABPropEntry *> *entries = WAGRCuratedConsistencyKVC(self, @"allCurated") ?: @[];
    BOOL requested = sender.isOn;
    NSUInteger attempted = 0, installed = 0, cleared = 0;
    for (WAGRABPropEntry *entry in entries) {
        if (!WAGRRuntimeValueTypeIsBoolean(entry.typeCode)) continue;
        if (!requested) {
            if (WAGRRuntimeValueHasOverride(entry.className, entry.selectorName, entry.classMethod)) {
                WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.classMethod);
                cleared++;
            }
            continue;
        }
        attempted++;
        WAGRRuntimeValueSetOverride(entry.className, entry.selectorName,
                                    entry.classMethod, entry.typeCode, @YES);
        if (WAGRRuntimeValueInstallHook(entry.className, entry.selectorName,
                                        entry.classMethod, entry.typeCode)) {
            installed++;
        } else {
            WAGRRuntimeValueClearOverride(entry.className, entry.selectorName, entry.classMethod);
        }
    }
    [((UITableViewController *)self).tableView reloadData];

    if (requested && installed != attempted) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Aplicação parcial"
            message:[NSString stringWithFormat:@"ABProps BOOL elegíveis: %lu\nHooks exatos instalados: %lu\nNão aplicados: %lu\n\nOs não aplicados foram removidos do mesmo RuntimeValueStore usado pelo ABProps Browser; portanto as duas telas permanecem coerentes.",
                     (unsigned long)attempted, (unsigned long)installed,
                     (unsigned long)(attempted - installed)]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
    } else if (!requested && cleared) {
        // Deliberately no alert for a successful clear; the updated cells are the
        // source-of-truth readback.
    }
}

static void WAGRCuratedConsistencyInstall(void) {
    Class cls = NSClassFromString(@"WAGRABPropsCuratedVC");
    if (!cls) return;
    Method row = class_getInstanceMethod(cls, NSSelectorFromString(@"rowSwitchChanged:"));
    if (row) method_setImplementation(row, (IMP)WAGRCuratedConsistencyRowSwitch);
    Method master = class_getInstanceMethod(cls, NSSelectorFromString(@"masterChanged:"));
    if (master) method_setImplementation(master, (IMP)WAGRCuratedConsistencyMaster);
}

__attribute__((constructor))
static void WAGRCuratedConsistencyCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRCuratedConsistencyInstall(); });
    }
}
