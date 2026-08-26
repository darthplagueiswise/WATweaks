#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Final visual tuning pass for the two high-density browsers.
// Installed after InlineTypedUI / FastTypedUI / GlassUI / ABPropsPerformanceUI so
// it only changes presentation, never runtime semantics or override state.

static NSMutableDictionary<NSString *, NSValue *> *gWAGRVisualCellOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRVisualLoadOriginals;

static NSString *WAGRVisualKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls) ?: @"?",
            NSStringFromSelector(selector) ?: @"?"];
}

static IMP WAGRVisualOriginal(id object, SEL selector,
                              NSDictionary<NSString *, NSValue *> *map) {
    for (Class cls = [object class]; cls; cls = class_getSuperclass(cls)) {
        NSValue *value = map[WAGRVisualKey(cls, selector)];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void WAGRVisualTuneCell(UITableViewCell *cell) {
    if (!cell) return;

    // Middle ground between the original 15/11.5 pt renderer and the overly
    // compact 11.5/8.75 pt pass. Keep one line, but do not let long names shrink
    // into unreadable micro-text.
    cell.textLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.62;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    cell.detailTextLabel.font = [UIFont systemFontOfSize:10.25 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.70;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    if ([cell.accessoryView isKindOfClass:UISwitch.class]) {
        // Give the selector a little more horizontal room while visually seating
        // the switch closer to the trailing edge. Transform preserves Auto Layout
        // ownership and the switch hit-testing geometry.
        cell.accessoryView.transform = CGAffineTransformMakeTranslation(5.0, 0.0);
    } else if ([cell.accessoryView isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)cell.accessoryView;
        field.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        field.minimumFontSize = 9.5;
        CGRect frame = field.frame;
        frame.size.width = MIN(frame.size.width, 108.0);
        frame.size.height = 31.0;
        field.frame = frame;
    }
}

static UITableViewCell *WAGRVisualCell(id self, SEL _cmd,
                                       UITableView *tableView,
                                       NSIndexPath *indexPath) {
    IMP original = WAGRVisualOriginal(self, _cmd, gWAGRVisualCellOriginals);
    UITableViewCell *cell = original
        ? ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))original)
            (self, _cmd, tableView, indexPath)
        : nil;
    WAGRVisualTuneCell(cell);
    return cell;
}

static void WAGRVisualDidLoad(id self, SEL _cmd) {
    IMP original = WAGRVisualOriginal(self, _cmd, gWAGRVisualLoadOriginals);
    if (original) ((void (*)(id, SEL))original)(self, _cmd);
    if ([self isKindOfClass:UITableViewController.class]) {
        UITableView *table = ((UITableViewController *)self).tableView;
        table.rowHeight = 54.0;
        table.estimatedRowHeight = 54.0;
    }
}

static void WAGRVisualWrap(Class cls, SEL selector, IMP replacement,
                           NSMutableDictionary<NSString *, NSValue *> *map) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (!current || current == replacement) return;
    map[WAGRVisualKey(cls, selector)] = [NSValue valueWithPointer:current];
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, replacement, types)) {
        method_setImplementation(method, replacement);
    }
}

static void WAGRRuntimeBrowserVisualTuningInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRVisualCellOriginals = [NSMutableDictionary dictionary];
        gWAGRVisualLoadOriginals = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"WAGRABPropsBrowserVC", @"WAGRSurfaceBrowserVC"]) {
            Class cls = NSClassFromString(name);
            WAGRVisualWrap(cls, @selector(viewDidLoad),
                           (IMP)WAGRVisualDidLoad, gWAGRVisualLoadOriginals);
            WAGRVisualWrap(cls, @selector(tableView:cellForRowAtIndexPath:),
                           (IMP)WAGRVisualCell, gWAGRVisualCellOriginals);
        }
    });
}

__attribute__((constructor))
static void WAGRRuntimeBrowserVisualTuningCtor(void) {
    @autoreleasepool {
        // ABPropsPerformanceUI installs at +0.70 s; remain the outermost visual
        // wrapper without changing the source-order semantics of the tweak.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WAGRRuntimeBrowserVisualTuningInstall();
        });
    }
}
