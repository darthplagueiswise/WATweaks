#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "WAGRABPropsRootVC.h"
#import "WAGRMobileConfigExportVC.h"
#import "../Runtime/WAGRMobileConfigBridge.h"
#import "../Runtime/WAGRLog.h"

extern id WAGRCurrentUserContext(void);

typedef void (*WAGRRootViewDidLoadIMP)(id, SEL);
static WAGRRootViewDidLoadIMP orig_WAGRABPropsRootViewDidLoad = NULL;
static BOOL gWAGRMobileConfigRootHooked = NO;
static const void *kWAGRMobileConfigButtonInstalledKey = &kWAGRMobileConfigButtonInstalledKey;

@implementation WAGRABPropsRootVC (WAGRMobileConfigExport)

- (void)wagr_openMobileConfigResolver:(__unused id)sender {
    WAGRMobileConfigEnsureCaptureHooksInstalled();
    WAGRMobileConfigExportVC *controller = [[WAGRMobileConfigExportVC alloc]
        initWithUserContext:WAGRCurrentUserContext()];
    [self.navigationController pushViewController:controller animated:YES];
}

@end

static void WAGRInstallMobileConfigButton(WAGRABPropsRootVC *controller) {
    if (!controller || [objc_getAssociatedObject(controller, kWAGRMobileConfigButtonInstalledKey) boolValue]) return;
    objc_setAssociatedObject(controller, kWAGRMobileConfigButtonInstalledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIBarButtonItem *mobileConfig = nil;
    if (@available(iOS 13.0, *)) {
        mobileConfig = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"point.3.connected.trianglepath.dotted"]
            style:UIBarButtonItemStylePlain
            target:controller
            action:@selector(wagr_openMobileConfigResolver:)];
        mobileConfig.accessibilityLabel = @"MobileConfig Resolver & Export";
    } else {
        mobileConfig = [[UIBarButtonItem alloc]
            initWithTitle:@"MC"
            style:UIBarButtonItemStylePlain
            target:controller
            action:@selector(wagr_openMobileConfigResolver:)];
    }

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    if (mobileConfig) [items addObject:mobileConfig];
    if (controller.navigationItem.rightBarButtonItems.count) {
        [items addObjectsFromArray:controller.navigationItem.rightBarButtonItems];
    } else if (controller.navigationItem.rightBarButtonItem) {
        [items addObject:controller.navigationItem.rightBarButtonItem];
    }
    controller.navigationItem.rightBarButtonItems = items;
    WAGRLogAppend(@"[MobileConfig] resolver/export button installed in AB Props root");
}

static void hook_WAGRABPropsRootViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRABPropsRootViewDidLoad) orig_WAGRABPropsRootViewDidLoad(self, _cmd);
    WAGRInstallMobileConfigButton((WAGRABPropsRootVC *)self);
}

static void WAGRMobileConfigMenuIntegrationInstall(void) {
    if (gWAGRMobileConfigRootHooked) return;
    Class cls = NSClassFromString(@"WAGRABPropsRootVC");
    SEL selector = @selector(viewDidLoad);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return;
    MSHookMessageEx(cls, selector, (IMP)hook_WAGRABPropsRootViewDidLoad,
                    (IMP *)&orig_WAGRABPropsRootViewDidLoad);
    gWAGRMobileConfigRootHooked = (orig_WAGRABPropsRootViewDidLoad != NULL);
}

__attribute__((constructor))
static void WAGRMobileConfigMenuIntegrationCtor(void) {
    @autoreleasepool {
        WAGRMobileConfigMenuIntegrationInstall();
        WAGRMobileConfigEnsureCaptureHooksInstalled();
    }
}
