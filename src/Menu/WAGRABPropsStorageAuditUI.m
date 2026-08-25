#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../Runtime/WAGRABPropsStorageAudit.h"
#import "../Runtime/WAGRABPropsNativeStore.h"

static void (*gWAGRStorageOrigSnapshotDidAppear)(id, SEL, BOOL) = NULL;
static BOOL gWAGRStorageSnapshotHooked = NO;
static const void *kWAGRStorageMenuInstalledKey = &kWAGRStorageMenuInstalledKey;

static id WAGRStorageKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void WAGRStorageShowAudit(UIViewController *controller) {
    NSString *text = WAGRABPropsStorageAuditText();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ABProps Storage Audit"
                                                                   message:text ?: @"Audit indisponível."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = text ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WAGRStorageConfigureSnapshotMenu(UIViewController *controller) {
    if (!controller || [objc_getAssociatedObject(controller, kWAGRStorageMenuInstalledKey) boolValue]) return;
    UIBarButtonItem *exportButton = WAGRStorageKVC(controller, @"exportButton");
    if (![exportButton isKindOfClass:UIBarButtonItem.class]) return;

    if (@available(iOS 14.0, *)) {
        __weak UIViewController *weakController = controller;
        UIAction *json = [UIAction actionWithTitle:@"Exportar JSON completo"
                                             image:[UIImage systemImageNamed:@"doc.badge.arrow.up"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {
            UIViewController *strong = weakController;
            SEL selector = NSSelectorFromString(@"exportJSON");
            if (strong && [strong respondsToSelector:selector]) {
                ((void (*)(id, SEL))objc_msgSend)(strong, selector);
            }
        }];
        UIAction *diagnostic = [UIAction actionWithTitle:@"Copiar diagnóstico ABProps"
                                                   image:[UIImage systemImageNamed:@"doc.on.doc"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
            UIPasteboard.generalPasteboard.string = WAGRABPropsNativeDiagnosticText() ?: @"";
        }];
        UIAction *storage = [UIAction actionWithTitle:@"Auditar armazenamento"
                                                image:[UIImage systemImageNamed:@"internaldrive"]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
            UIViewController *strong = weakController;
            if (strong) WAGRStorageShowAudit(strong);
        }];
        exportButton.menu = [UIMenu menuWithTitle:@"ABProps"
                                         children:@[json, diagnostic, storage]];
        exportButton.target = nil;
        exportButton.action = nil;
        exportButton.accessibilityLabel = @"Exportar ou auditar armazenamento ABProps";
    }
    objc_setAssociatedObject(controller, kWAGRStorageMenuInstalledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WAGRStorageSnapshotDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gWAGRStorageOrigSnapshotDidAppear) gWAGRStorageOrigSnapshotDidAppear(self, _cmd, animated);
    WAGRStorageConfigureSnapshotMenu((UIViewController *)self);
}

static void WAGRStorageInstallSnapshotHook(void) {
    if (gWAGRStorageSnapshotHooked) return;
    Class cls = NSClassFromString(@"WAGRABPropsSnapshotVC");
    if (!cls) return;
    Method inherited = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!inherited) return;
    IMP current = method_getImplementation(inherited);
    if (current == (IMP)WAGRStorageSnapshotDidAppear) {
        gWAGRStorageSnapshotHooked = YES;
        return;
    }
    const char *types = method_getTypeEncoding(inherited);
    gWAGRStorageOrigSnapshotDidAppear = (void (*)(id, SEL, BOOL))current;
    if (!class_addMethod(cls, @selector(viewDidAppear:), (IMP)WAGRStorageSnapshotDidAppear, types)) {
        Method own = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (!own) return;
        method_setImplementation(own, (IMP)WAGRStorageSnapshotDidAppear);
    }
    gWAGRStorageSnapshotHooked = YES;
}

__attribute__((constructor))
static void WAGRABPropsStorageAuditUICtor(void) {
    @autoreleasepool {
        WAGRStorageInstallSnapshotHook();
        dispatch_async(dispatch_get_main_queue(), ^{ WAGRStorageInstallSnapshotHook(); });
    }
}
