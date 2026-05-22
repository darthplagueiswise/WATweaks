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
            @"class=%@\nloaded=%@\ninheritance=%@\ninitSelectors=%@\n\nLauncher diagnostic:\n%@\n\nSafe policy:\nDirect instantiation is blocked because these Swift/hidden controllers can trap during init/dealloc when WAContext/UserContext/FOA state is missing.",
            className ?: @"n/a",
            cls ? @"YES" : @"NO",
            WAGRDebugVCInheritance(cls),
            inits.count ? [inits componentsJoinedByString:@", "] : @"none",
            WAGRDebugMenuLauncherDiagnosticText() ?: @"n/a"];
}

@interface WAGRDebugVCInstantiatorVC ()
@property(nonatomic, strong) NSArray<NSString *> *classes;
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
    return @"Tap a class to copy diagnostics. Direct open is intentionally blocked to avoid Swift runtime traps on close/dismiss.";
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
    c.accessoryType = UITableViewCellAccessoryDetailButton;
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

- (void)showClassActions:(NSString *)className {
    NSString *report = WAGRDebugVCReport(className);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:className
                                                               message:@"Direct instantiation is blocked. Use diagnostics or copy the class name."
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
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
    [self showText:@"Debug launcher" body:WAGRDebugMenuLauncherDiagnosticText() ?: @"n/a"];
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
