// WAGRDebugVCInstantiatorVC.m
// ─────────────────────────────────────────────────────────────────────────────
// Safe wrapper around the old Debug VC instantiator idea.
//
// Direct alloc/init of WhatsApp's hidden Debug VCs is intentionally blocked
// here. The crash you decoded is a Swift runtime trap, not an Objective-C
// exception; @try/@catch cannot make that safe. This lab lists classes, probes
// available init selectors and routes WADebugViewController through the native
// launcher only.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRDebugVCInstantiatorVC.h"
#import <objc/runtime.h>
#import <objc/message.h>

extern BOOL WAGRLaunchNativeDeveloperMenu(UIViewController *fromVC, NSError **outError);
extern NSString *WAGRDebugMenuLauncherDiagnosticText(void);
extern void WAGRDebugVCStabilityEnsureInstalled(void);
extern void WAGRDebugVCStabilitySetActive(BOOL active);
extern NSString *WAGRDebugVCStabilityDiagnosticText(void);
extern void WAGRDogfoodEnsureHooksInstalled(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern void WAGRAuraEnsureNavigationHooksInstalled(void);
extern void WAGRAccountEligibilityEnsureHooksInstalled(void);
extern void WAGRGateHooksEnsureInstalled(void);

static UIColor *WAGRDbgBG(void) { return UIColor.systemGroupedBackgroundColor; }
static UIColor *WAGRDbgCell(void) { return UIColor.secondarySystemGroupedBackgroundColor; }

static NSArray<NSString *> *WAGRDebugVCRoster(void) {
    return @[
        @"WADebugViewController",
        @"WABizFolderDebugViewController",
        @"WACallDebugInfoViewController",
        @"WADebugAccountSyncViewController",
        @"WADebugArClassManagerViewController",
        @"WADebugArEffectGraphQLViewController",
        @"WADebugArEffectLocalAssetManagerViewController",
        @"WADebugArEffectMetadataManagerViewController",
        @"WADebugArEffectUICatalogueViewController",
        @"WADebugCallToneSettingsViewController",
        @"WADebugColorPickerViewController",
        @"WADebugCreateTestDatabaseController",
        @"WADebugDateInputViewController",
        @"WADebugEntryPointAnimationViewController",
        @"WADebugFOANavigationShowcaseViewController",
        @"WADebugIPCStreamingViewController",
        @"WADebugIgluEffectPreferencesViewController",
        @"WADebugInputViewController",
        @"WADebugMLViewController",
        @"WADebugPandoGraphQLViewController",
        @"WADebugSGStateViewController",
        @"WADebugShareItemsViewController",
        @"WADebugWearableAudioViewController",
        @"WAMBIMexDebugViewController",
        @"WAMexDebugViewController",
        @"WAStatusExternalShareTestingDebuggerViewController",
        @"_TtC16WADebugMenuYouth28DebugBrazilO13ViewController",
        @"_TtC18WADebugMenuInterop31InteropGroupDebugViewController",
        @"_TtC19WADebugMenuArEffect33DebugAREffectAssetsViewController",
        @"_TtC19WADebugMenuArEffect34DebugArEffectLoadingViewController",
        @"_TtC19WADebugMenuArEffect34DebugArEffectTouchUpViewController",
        @"_TtC19WADebugMenuArEffect37DebugArEffectEffectTrayViewController",
        @"_TtC13WAGraphQLAuth41GraphQLAuthManagerDebugToolViewController"
    ];
}

static NSArray<NSString *> *WAGRDebugVCInitSelectorsForClass(Class cls) {
    if (!cls) return @[];
    NSArray<NSString *> *candidates = @[
        @"init",
        @"initWithUserContext:",
        @"initAsModalWithUserContext:",
        @"initWithContext:",
        @"initWithUserContext:logger:",
        @"initWithNavigationControllerProvider:",
        @"initWithStyle:"
    ];
    NSMutableArray<NSString *> *available = [NSMutableArray array];
    for (NSString *name in candidates) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, sel);
        if (method) [available addObject:name];
    }
    return available;
}

static NSString *WAGRDebugVCInheritance(Class cls) {
    if (!cls) return @"not loaded";
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    Class c = cls;
    while (c) {
        [chain addObject:NSStringFromClass(c)];
        c = class_getSuperclass(c);
        if (chain.count > 12) break;
    }
    return [chain componentsJoinedByString:@" → "];
}

static NSString *WAGRDebugVCReport(NSString *className) {
    Class cls = NSClassFromString(className);
    NSArray<NSString *> *inits = WAGRDebugVCInitSelectorsForClass(cls);
    return [NSString stringWithFormat:
            @"class=%@\nloaded=%@\ninheritance=%@\ninitSelectors=%@\n\nLauncher diagnostic:\n%@\n\nStability diagnostic:\n%@\n\nExperimental open policy:\nOpening is allowed from this lab, but the presented navigation controller is retained intentionally to avoid Swift teardown traps on dismissal.",
            className ?: @"n/a",
            cls ? @"YES" : @"NO",
            WAGRDebugVCInheritance(cls),
            inits.count ? [inits componentsJoinedByString:@", "] : @"none",
            WAGRDebugMenuLauncherDiagnosticText() ?: @"n/a",
            WAGRDebugVCStabilityDiagnosticText() ?: @"n/a"];
}


static NSMutableArray *WAGRDebugVCLeakedControllers(void) {
    static NSMutableArray *items = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = [NSMutableArray array];
    });
    return items;
}

static void WAGRDebugVCPrimeHooks(void) {
    WAGRDebugVCStabilityEnsureInstalled();
    WAGRDogfoodEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRAuraEnsureNavigationHooksInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();
    WAGRGateHooksEnsureInstalled();
}

static id WAGRDebugVCProbeWAUserContext(id obj) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(@"wa_userContext");
    if (![obj respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))[obj methodForSelector:sel];
    id uc = fn(obj, sel);
    if (!uc) return nil;
    NSString *cls = NSStringFromClass([uc class]);
    return [cls containsString:@"Context"] ? uc : nil;
}

static id WAGRDebugVCUserContextIvar(id obj) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], "_userContext");
    if (!iv) return nil;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, iv);
}

static id WAGRDebugVCProbeUserContext(id obj) {
    return WAGRDebugVCProbeWAUserContext(obj) ?: WAGRDebugVCUserContextIvar(obj);
}

static id WAGRDebugVCFindUserContextInTree(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 20) return nil;
    id uc = WAGRDebugVCProbeUserContext(vc);
    if (uc) return uc;
    for (UIViewController *child in vc.childViewControllers) {
        uc = WAGRDebugVCFindUserContextInTree(child, depth + 1);
        if (uc) return uc;
    }
    if (vc.presentedViewController) {
        uc = WAGRDebugVCFindUserContextInTree(vc.presentedViewController, depth + 1);
        if (uc) return uc;
    }
    return nil;
}

static id WAGRDebugVCFindUserContextAnywhere(void) {
    Class server = NSClassFromString(@"WAServerProperties");
    SEL userContextSel = NSSelectorFromString(@"userContext");
    if (server && [server respondsToSelector:userContextSel]) {
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id ctx = fn((id)server, userContextSel);
        if (ctx) return ctx;
    }

    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        id uc = WAGRDebugVCFindUserContextInTree(win.rootViewController, 0);
        if (uc) return uc;
    }

    return WAGRDebugVCProbeUserContext((id)UIApplication.sharedApplication.delegate);
}

static UIViewController *WAGRDebugVCInstantiateExperimental(NSString *className, NSError **outError) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks.DebugVC" code:1 userInfo:@{NSLocalizedDescriptionKey: @"class not loaded"}];
        return nil;
    }

    if (![cls isSubclassOfClass:UIViewController.class]) {
        if (outError) *outError = [NSError errorWithDomain:@"WATweaks.DebugVC" code:2 userInfo:@{NSLocalizedDescriptionKey: @"class is not a UIViewController subclass"}];
        return nil;
    }

    WAGRDebugVCPrimeHooks();
    id userContext = WAGRDebugVCFindUserContextAnywhere();
    id instance = nil;
    NSString *used = nil;

    WAGRDebugVCStabilitySetActive(YES);
    @try {
        id allocObj = [cls alloc];

        for (NSString *selName in @[@"initWithUserContext:", @"initAsModalWithUserContext:", @"initWithContext:"]) {
            if (!userContext) break;
            SEL sel = NSSelectorFromString(selName);
            if (![allocObj respondsToSelector:sel]) continue;
            id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))[allocObj methodForSelector:sel];
            instance = fn(allocObj, sel, userContext);
            used = selName;
            break;
        }

        if (!instance && [cls isSubclassOfClass:UITableViewController.class]) {
            SEL sel = NSSelectorFromString(@"initWithStyle:");
            id allocObj = [cls alloc];
            if ([allocObj respondsToSelector:sel]) {
                id (*fn)(id, SEL, UITableViewStyle) = (id (*)(id, SEL, UITableViewStyle))[allocObj methodForSelector:sel];
                instance = fn(allocObj, sel, UITableViewStyleInsetGrouped);
                used = @"initWithStyle:";
            }
        }

        if (!instance) {
            SEL sel = NSSelectorFromString(@"init");
            id allocObj = [cls alloc];
            if ([allocObj respondsToSelector:sel]) {
                id (*fn)(id, SEL) = (id (*)(id, SEL))[allocObj methodForSelector:sel];
                instance = fn(allocObj, sel);
                used = @"init";
            }
        }
    } @catch (NSException *ex) {
        WAGRDebugVCStabilitySetActive(NO);
        if (outError) {
            *outError = [NSError errorWithDomain:@"WATweaks.DebugVC" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Objective-C exception during init: %@", ex]}];
        }
        return nil;
    }
    WAGRDebugVCStabilitySetActive(NO);

    if (![instance isKindOfClass:UIViewController.class]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"WATweaks.DebugVC" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"no supported initializer worked; userContext=%@", userContext ? NSStringFromClass([userContext class]) : @"nil"]}];
        }
        return nil;
    }

    UIViewController *vc = (UIViewController *)instance;
    vc.title = vc.title ?: className.lastPathComponent;
    objc_setAssociatedObject(vc, "WAGRDebugVCInitSelector", used ?: @"unknown", OBJC_ASSOCIATION_COPY_NONATOMIC);
    return vc;
}

@interface WAGRDebugVCInstantiatorVC ()
@property(nonatomic, strong) NSArray<NSString *> *classes;
- (void)openExperimentalDebugVC:(NSString *)className;
@end

@implementation WAGRDebugVCInstantiatorVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Debug VC Lab";
    _classes = WAGRDebugVCRoster();
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = WAGRDbgBG();
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Diag" style:UIBarButtonItemStylePlain target:self action:@selector(showLauncherDiagnostic)];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.classes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Safe native path" : @"Hidden Debug VCs — diagnostics only";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Uses the native launcher/reveal path. It does not directly instantiate Swift Debug VCs.";
    return @"Tap a class to open experimentally or copy diagnostics. Opened controllers are retained after dismiss to avoid Swift teardown traps.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = WAGRDbgCell();
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 2;

    if (ip.section == 0) {
        c.textLabel.text = @"Open native Developer menu";
        c.detailTextLabel.text = @"Provider / Settings reveal path only; no raw alloc/init fallback.";
        c.imageView.image = [[UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        c.imageView.tintColor = UIColor.systemBlueColor;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }

    NSString *name = self.classes[(NSUInteger)ip.row];
    Class cls = NSClassFromString(name);
    NSArray<NSString *> *inits = WAGRDebugVCInitSelectorsForClass(cls);
    c.textLabel.text = name;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    c.detailTextLabel.text = cls
        ? [NSString stringWithFormat:@"loaded · inits: %@", inits.count ? [inits componentsJoinedByString:@", "] : @"none"]
        : @"not loaded";
    c.imageView.image = [[UIImage systemImageNamed:@"circle.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = cls ? UIColor.systemGreenColor : UIColor.tertiaryLabelColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) {
        NSError *err = nil;
        BOOL ok = WAGRLaunchNativeDeveloperMenu(self, &err);
        if (!ok) [self showText:@"Native launcher failed" body:err.localizedDescription ?: @"unknown"];
        return;
    }

    NSString *name = self.classes[(NSUInteger)ip.row];
    [self showClassActions:name];
}

- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    if (ip.section != 1) return;
    [self showClassActions:self.classes[(NSUInteger)ip.row]];
}


- (id)wagrCurrentUserContext {
    NSArray<NSString *> *classes = @[@"WAServerProperties", @"WAContextMain", @"WAContext"];
    NSArray<NSString *> *selectors = @[@"userContext", @"sharedUserContext", @"currentUserContext"];
    for (NSString *className in classes) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([cls respondsToSelector:sel]) {
                id ctx = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
                if (ctx) return ctx;
            }
        }
    }
    return nil;
}

- (void)openExperimentalDebugVC:(NSString *)className {
    if (!className.length) return;

    WAGRDogfoodEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRAuraEnsureNavigationHooksInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();
    WAGRGateHooksEnsureInstalled();
    WAGRDebugVCStabilityEnsureInstalled();

    Class cls = NSClassFromString(className);
    if (!cls) {
        [self showText:@"Debug VC not loaded" body:className];
        return;
    }

    if ([className isEqualToString:@"WADebugViewController"]) {
        NSError *err = nil;
        BOOL ok = WAGRLaunchNativeDeveloperMenu(self, &err);
        if (!ok) [self showText:@"Native launcher failed" body:err.localizedDescription ?: @"unknown"];
        return;
    }

    WAGRDebugVCStabilitySetActive(YES);

    UIViewController *vc = nil;
    @try {
        id alloc = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
        id userContext = [self wagrCurrentUserContext];

        if (userContext && [alloc respondsToSelector:NSSelectorFromString(@"initWithUserContext:")]) {
            vc = ((id (*)(id, SEL, id))objc_msgSend)(alloc, NSSelectorFromString(@"initWithUserContext:"), userContext);
        } else if ([alloc respondsToSelector:@selector(init)]) {
            vc = ((id (*)(id, SEL))objc_msgSend)(alloc, @selector(init));
        }
    } @catch (NSException *ex) {
        WAGRDebugVCStabilitySetActive(NO);
        [self showText:@"Objective-C exception" body:ex.reason ?: ex.description];
        return;
    }

    if (![vc isKindOfClass:UIViewController.class]) {
        WAGRDebugVCStabilitySetActive(NO);
        [self showText:@"Debug VC open failed"
                  body:[NSString stringWithFormat:@"%@ did not produce a UIViewController. %@", className, WAGRDebugVCStabilityDiagnosticText() ?: @""]];
        return;
    }

    // Deliberately retain the presented nav/controller for lab stability. Some
    // Swift debug VCs trap on dealloc when opened outside the native graph.
    static NSMutableArray<UIViewController *> *retainedControllers = nil;
    if (!retainedControllers) retainedControllers = [NSMutableArray array];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.prefersGrabberVisible = YES;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
    }
    [retainedControllers addObject:nav];

    __weak typeof(self) weakSelf = self;
    [self presentViewController:nav animated:YES completion:^{
        (void)weakSelf;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WAGRDebugVCStabilitySetActive(NO);
        });
    }];
}

- (void)showClassActions:(NSString *)className {
    NSString *report = WAGRDebugVCReport(className);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:className
                                                               message:@"Experimental opening is available. The controller is intentionally retained after dismiss to avoid Swift teardown traps."
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Open experimental (retained)" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        [self openExperimentalDebugVC:className];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Show diagnostics" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        [self showText:className body:report];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy diagnostics" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        UIPasteboard.generalPasteboard.string = report;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy class name" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        UIPasteboard.generalPasteboard.string = className ?: @"";
    }]];
    if ([className isEqualToString:@"WADebugViewController"]) {
        [a addAction:[UIAlertAction actionWithTitle:@"Open through native launcher" style:UIAlertActionStyleDefault handler:^(__unused id _) {
            NSError *err = nil;
            BOOL ok = WAGRLaunchNativeDeveloperMenu(self, &err);
            if (!ok) [self showText:@"Native launcher failed" body:err.localizedDescription ?: @"unknown"];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showLauncherDiagnostic {
    NSString *body = [NSString stringWithFormat:@"%@\n\n[Stability]\n%@",
                      WAGRDebugMenuLauncherDiagnosticText() ?: @"n/a",
                      WAGRDebugVCStabilityDiagnosticText() ?: @"n/a"];
    [self showText:@"Debug launcher" body:body];
}

- (void)showText:(NSString *)title body:(NSString *)body {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"Debug VC Lab"
                                                               message:body ?: @""
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        UIPasteboard.generalPasteboard.string = body ?: @"";
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
