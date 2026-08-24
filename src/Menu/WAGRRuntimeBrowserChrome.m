#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*orig_WAGRSurfaceCompactViewDidLoad)(id, SEL) = NULL;
static void (*orig_WAGRSurfaceCompactApplyFilter)(id, SEL) = NULL;

static NSUInteger WAGRSurfaceCompactVisibleCount(id self) {
    NSArray *keys = nil;
    NSDictionary *sections = nil;
    @try { keys = [self valueForKey:@"sectionKeys"]; sections = [self valueForKey:@"sections"]; }
    @catch (__unused NSException *e) { return 0; }
    NSUInteger total = 0;
    for (NSString *key in keys ?: @[]) {
        NSArray *rows = [sections[key] isKindOfClass:NSArray.class] ? sections[key] : nil;
        total += rows.count;
    }
    return total;
}

static void hook_WAGRSurfaceCompactViewDidLoad(id self, SEL _cmd) {
    if (orig_WAGRSurfaceCompactViewDidLoad) orig_WAGRSurfaceCompactViewDidLoad(self, _cmd);
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)self;
    UITableView *table = [controller respondsToSelector:@selector(tableView)] ? [(id)controller tableView] : nil;
    table.estimatedRowHeight = 58.0;
    table.rowHeight = UITableViewAutomaticDimension;

    NSArray<UIBarButtonItem *> *items = controller.navigationItem.rightBarButtonItems;
    UIBarButtonItem *refresh = items.lastObject;
    controller.navigationItem.rightBarButtonItems = refresh ? @[refresh] : @[];
}

static void hook_WAGRSurfaceCompactApplyFilter(id self, SEL _cmd) {
    if (orig_WAGRSurfaceCompactApplyFilter) orig_WAGRSurfaceCompactApplyFilter(self, _cmd);
    if (![self isKindOfClass:UIViewController.class]) return;
    ((UIViewController *)self).title = [NSString stringWithFormat:@"Runtime (%lu)",
        (unsigned long)WAGRSurfaceCompactVisibleCount(self)];
}

__attribute__((constructor))
static void WAGRRuntimeBrowserChromeCtor(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"WAGRSurfaceBrowserVC");
        if (!cls) return;

        Method load = class_getInstanceMethod(cls, @selector(viewDidLoad));
        if (load) {
            orig_WAGRSurfaceCompactViewDidLoad = (void (*)(id, SEL))method_getImplementation(load);
            method_setImplementation(load, (IMP)hook_WAGRSurfaceCompactViewDidLoad);
        }

        SEL filterSelector = NSSelectorFromString(@"applyCurrentFilter");
        Method filter = class_getInstanceMethod(cls, filterSelector);
        if (filter) {
            orig_WAGRSurfaceCompactApplyFilter = (void (*)(id, SEL))method_getImplementation(filter);
            method_setImplementation(filter, (IMP)hook_WAGRSurfaceCompactApplyFilter);
        }
    }
}
