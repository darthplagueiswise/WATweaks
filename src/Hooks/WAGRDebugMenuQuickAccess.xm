// WAGRDebugMenuQuickAccess.xm
// Stable navigation affordances for WhatsApp's native WADebugViewController.
// This deliberately does not mutate WADebugViewController's table datasource;
// previous section/row injection could desync WhatsApp's private WATableSection cache.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../Runtime/WAGRLog.h"
#import "../Menu/WAGRRuntimeGatesVC.h"

static const char *kWAGRDebugQuickAccessTargetKey = "watweaks.debug.quickaccess.target";
static const char *kWAGRDebugQuickAccessInstalledKey = "watweaks.debug.quickaccess.installed";

typedef void (*WAGRQAViewDidLoadIMP)(id, SEL);
typedef void (*WAGRQAViewDidAppearIMP)(id, SEL, BOOL);

static WAGRQAViewDidLoadIMP gWAGRQAOrigViewDidLoad = NULL;
static WAGRQAViewDidAppearIMP gWAGRQAOrigViewDidAppear = NULL;
static BOOL gWAGRQAInstalled = NO;

@interface WAGRDebugMenuQuickAccessTarget : NSObject
@property(nonatomic, weak) UIViewController *owner;
- (void)wagrOpenWATweaks:(id)sender;
- (void)wagrBack:(id)sender;
@end

@implementation WAGRDebugMenuQuickAccessTarget

- (void)wagrOpenWATweaks:(__unused id)sender {
    UIViewController *owner = self.owner;
    if (!owner) return;

    WAGRRuntimeGatesVC *menu = [WAGRRuntimeGatesVC new];
    menu.title = @"WATweaks";

    UINavigationController *nav = owner.navigationController;
    if (nav) {
        [nav pushViewController:menu animated:YES];
        return;
    }

    UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:menu];
    wrap.modalPresentationStyle = UIModalPresentationFormSheet;
    [owner presentViewController:wrap animated:YES completion:nil];
}

- (void)wagrBack:(__unused id)sender {
    UIViewController *vc = self.owner;
    if (!vc) return;

    UINavigationController *nav = vc.navigationController;
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        return;
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (nav.presentingViewController) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

static BOOL WAGRQAIsDebugVC(id obj) {
    return obj && [NSStringFromClass([obj class]) isEqualToString:@"WADebugViewController"];
}

static BOOL WAGRQAItemsContainIdentifier(NSArray<UIBarButtonItem *> *items, NSString *identifier) {
    for (UIBarButtonItem *item in items) {
        if ([item.accessibilityIdentifier isEqualToString:identifier]) return YES;
    }
    return NO;
}

static void WAGRQAInstallButtons(id self) {
    if (!WAGRQAIsDebugVC(self) || ![self isKindOfClass:UIViewController.class]) return;

    UIViewController *vc = (UIViewController *)self;
    WAGRDebugMenuQuickAccessTarget *target = objc_getAssociatedObject(vc, kWAGRDebugQuickAccessTargetKey);
    if (!target) {
        target = [WAGRDebugMenuQuickAccessTarget new];
        objc_setAssociatedObject(vc, kWAGRDebugQuickAccessTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    target.owner = vc;

    if (!vc.navigationItem.leftBarButtonItem) {
        UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"Voltar"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:target
                                                                action:@selector(wagrBack:)];
        back.accessibilityIdentifier = @"WATweaksDebugBackButton";
        vc.navigationItem.leftBarButtonItem = back;
    }

    NSMutableArray<UIBarButtonItem *> *right = [NSMutableArray array];
    if (vc.navigationItem.rightBarButtonItems.count) {
        [right addObjectsFromArray:vc.navigationItem.rightBarButtonItems];
    } else if (vc.navigationItem.rightBarButtonItem) {
        [right addObject:vc.navigationItem.rightBarButtonItem];
    }

    if (!WAGRQAItemsContainIdentifier(right, @"WATweaksDebugQuickAccessButton")) {
        UIBarButtonItem *open = [[UIBarButtonItem alloc] initWithTitle:@"WATweaks"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:target
                                                                action:@selector(wagrOpenWATweaks:)];
        open.accessibilityIdentifier = @"WATweaksDebugQuickAccessButton";
        [right insertObject:open atIndex:0];
        vc.navigationItem.rightBarButtonItems = right;
        WAGRLogAppendF(@"[DebugMenuQuickAccess] installed nav buttons on %@", NSStringFromClass([vc class]));
    }
}

static void WAGRQAViewDidLoad(id self, SEL _cmd) {
    if (gWAGRQAOrigViewDidLoad) gWAGRQAOrigViewDidLoad(self, _cmd);
    WAGRQAInstallButtons(self);
}

static void WAGRQAViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gWAGRQAOrigViewDidAppear) gWAGRQAOrigViewDidAppear(self, _cmd, animated);
    WAGRQAInstallButtons(self);
}

static void WAGRQAEnsureInstalled(void) {
    if (gWAGRQAInstalled) return;
    Class cls = NSClassFromString(@"WADebugViewController");
    if (!cls) return;

    MSHookMessageEx(cls, @selector(viewDidLoad), (IMP)WAGRQAViewDidLoad, (IMP *)&gWAGRQAOrigViewDidLoad);
    MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)WAGRQAViewDidAppear, (IMP *)&gWAGRQAOrigViewDidAppear);
    gWAGRQAInstalled = YES;
    WAGRLogAppendF(@"[DebugMenuQuickAccess] installed WADebugViewController nav hooks");
}

static void WAGRQAScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WAGRQAEnsureInstalled();
    });
}

__attribute__((constructor))
static void WAGRDebugMenuQuickAccessCtor(void) {
    @autoreleasepool {
        WAGRQAEnsureInstalled();
        WAGRQAScheduleRetry(0.2);
        WAGRQAScheduleRetry(1.0);
        WAGRQAScheduleRetry(3.0);
    }
}
