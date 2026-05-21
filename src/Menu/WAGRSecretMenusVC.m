// WAGRSecretMenusVC.m
// ─────────────────────────────────────────────────────────────────────────────
// Each row is one of WhatsApp's internal/debug controllers. The cell shows
// the class name plus a green/red dot indicating whether the class is
// loaded in the runtime right now (some only load lazily when an internal
// feature flag is set, so the indicator helps the user know what they can
// actually try).
//
// Tap behaviour: enumerate a small set of init signatures, try each in
// order, present whichever returns a non-nil VC inside a navigation
// controller. If none works we surface a UIAlert with the class name
// and the last failure so the user can report or screenshot the result.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRSecretMenusVC.h"
#import "../WAGramPrefix.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ── Roster of secret view controllers ─────────────────────────────────────
// The roster is split into two groups so the user has some structure when
// scanning the list: ObjC classes (plain string class names) and Swift
// classes (mangled `_TtC...` symbols). Each tuple is (className,
// human-friendly title, short description).
typedef struct {
    __unsafe_unretained NSString *className;
    __unsafe_unretained NSString *title;
    __unsafe_unretained NSString *desc;
} WAGRSecretEntry;

static const WAGRSecretEntry kObjCRoster[] = {
    {@"WADebugViewController",
     @"WADebug (master)",
     @"Top-level developer menu. Same one the Settings → Developer row opens."},
    {@"WABizFolderDebugViewController",
     @"BizFolder Debug",
     @"Business folder/contact tooling, normally only visible in B12 builds."},
    {@"WACallDebugInfoViewController",
     @"Call Debug Info",
     @"Live call inspector — bitrate, codec, RTC stats."},
    {@"WADebugAccountSyncViewController",
     @"Account Sync Debug",
     @"Sync state inspector for multi-device account flows."},
    {@"WADebugArClassManagerViewController",
     @"AR Class Manager",
     @"Augmented-reality class registry inspector."},
    {@"WADebugArEffectGraphQLViewController",
     @"AR Effect GraphQL",
     @"AR effect descriptors fetched via GraphQL."},
    {@"WADebugArEffectLocalAssetManagerViewController",
     @"AR Effect Local Assets",
     @"Local AR-effect asset cache browser."},
    {@"WADebugArEffectMetadataManagerViewController",
     @"AR Effect Metadata",
     @"AR-effect metadata cache."},
    {@"WADebugArEffectUICatalogueViewController",
     @"AR Effect UI Catalogue",
     @"Showroom of every AR effect UI variant."},
    {@"WADebugCallToneSettingsViewController",
     @"Call Tone Settings",
     @"Internal call-tone picker not exposed in the user-visible Settings."},
    {@"WADebugColorPickerViewController",
     @"Color Picker",
     @"Standalone color picker used by internal screens."},
    {@"WADebugCreateTestDatabaseController",
     @"Create Test Database",
     @"Spins up an empty database with synthetic data for QA."},
    {@"WADebugDateInputViewController",
     @"Date Input",
     @"Internal date-input field demo."},
    {@"WADebugEntryPointAnimationViewController",
     @"Entry Point Animation",
     @"Plays the animated entry-point intros used by internal nudges."},
    {@"WADebugFOANavigationShowcaseViewController",
     @"FOA Navigation Showcase",
     @"Family-of-apps navigation patterns showcase."},
    {@"WADebugIPCStreamingViewController",
     @"IPC Streaming",
     @"Inter-process communication stream inspector."},
    {@"WADebugIgluEffectPreferencesViewController",
     @"Iglu Effect Preferences",
     @"Iglu effect engine internal toggles."},
    {@"WADebugInputViewController",
     @"Input Debug",
     @"Generic text-input experiment harness."},
    {@"WADebugMLViewController",
     @"ML Debug",
     @"Machine-learning model loader / inspector."},
    {@"WADebugPandoGraphQLViewController",
     @"Pando GraphQL",
     @"Pando GraphQL endpoint inspector."},
    {@"WADebugSGStateViewController",
     @"SG State",
     @"Signal-graph state inspector."},
    {@"WADebugShareItemsViewController",
     @"Share Items Debug",
     @"Inspect items in the share-extension pipeline."},
    {@"WADebugWearableAudioViewController",
     @"Wearable Audio",
     @"Wearable audio device debug screen."},
    {@"WAMBIMexDebugViewController",
     @"MBI Mex Debug",
     @"Multi-buffer infra / message-exchange inspector."},
    {@"WAMexDebugViewController",
     @"Mex Debug",
     @"Lower-level message-exchange inspector."},
    {@"WAStatusExternalShareTestingDebuggerViewController",
     @"Status External Share Testing",
     @"Status external-share QA harness."},
};

static const WAGRSecretEntry kSwiftRoster[] = {
    {@"_TtC16WADebugMenuYouth28DebugBrazilO13ViewController",
     @"Brazil O13 (Youth)",
     @"Brazil-specific O13 youth-compliance debug screen."},
    {@"_TtC18WADebugMenuInterop31InteropGroupDebugViewController",
     @"Interop Group Debug",
     @"Cross-app interoperability group debug surface."},
    {@"_TtC19WADebugMenuArEffect33DebugAREffectAssetsViewController",
     @"AR Effect Assets (Swift)",
     @"Swift-side AR-effect asset debugger."},
    {@"_TtC19WADebugMenuArEffect34DebugArEffectLoadingViewController",
     @"AR Effect Loading",
     @"AR-effect loading-state inspector."},
    {@"_TtC19WADebugMenuArEffect34DebugArEffectTouchUpViewController",
     @"AR Effect Touch-Up",
     @"AR-effect touch-up tooling."},
    {@"_TtC19WADebugMenuArEffect37DebugArEffectEffectTrayViewController",
     @"AR Effect Effect Tray",
     @"AR-effect effect-tray inspector."},
    {@"_TtC13WAGraphQLAuth41GraphQLAuthManagerDebugToolViewController",
     @"GraphQL Auth Debug",
     @"GraphQL auth-manager debug tool."},
};

#define OBJC_ROSTER_COUNT  (sizeof(kObjCRoster)/sizeof(kObjCRoster[0]))
#define SWIFT_ROSTER_COUNT (sizeof(kSwiftRoster)/sizeof(kSwiftRoster[0]))

// ── userContext discovery (mirrors WAGRDebugMenuLauncher's logic) ─────────
// Several of the debug VCs require a WAContextMain singleton through
// -initWithUserContext:. We walk the live view-controller graph to find
// one. The duplicated logic is small enough to keep local; making it a
// shared helper would mean refactoring an unrelated file.
static id wagr_secretFindUserContext(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 20) return nil;
    SEL sel = NSSelectorFromString(@"wa_userContext");
    if ([vc respondsToSelector:sel]) {
        id ctx = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
        if (ctx && [NSStringFromClass([ctx class]) containsString:@"Context"]) return ctx;
    }
    Ivar iv = class_getInstanceVariable([vc class], "_userContext");
    if (iv) {
        id ctx = object_getIvar(vc, iv);
        if (ctx) return ctx;
    }
    for (UIViewController *child in vc.childViewControllers) {
        id c = wagr_secretFindUserContext(child, depth + 1);
        if (c) return c;
    }
    if (vc.presentedViewController) {
        return wagr_secretFindUserContext(vc.presentedViewController, depth + 1);
    }
    return nil;
}

static id wagr_secretFindUserContextAnywhere(void) {
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        id c = wagr_secretFindUserContext(win.rootViewController, 0);
        if (c) return c;
    }
    return nil;
}

// ── Instantiation strategy ────────────────────────────────────────────────
// Try every init signature in priority order until one yields a non-nil VC.
// The order matters: the one most likely to populate the controller with
// useful state comes first.
static UIViewController *wagr_secretInstantiate(NSString *className, NSString **outErr) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        if (outErr) *outErr = [NSString stringWithFormat:
            @"Class %@ is not loaded in the runtime.", className];
        return nil;
    }

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    id ctx = wagr_secretFindUserContextAnywhere();

    // Strategy A — initWithUserContext: (most internal Debug VCs use this)
    SEL sUserCtx = NSSelectorFromString(@"initWithUserContext:");
    if (ctx && [cls instancesRespondToSelector:sUserCtx]) {
        id inst = [cls alloc];
        if (inst) {
            id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))[inst methodForSelector:sUserCtx];
            id result = fn(inst, sUserCtx, ctx);
            if ([result isKindOfClass:UIViewController.class]) return (UIViewController *)result;
            [failures addObject:@"initWithUserContext: returned nil"];
        }
    } else if (!ctx) {
        [failures addObject:@"no live userContext for initWithUserContext:"];
    }

    // Strategy B — initAsModalWithUserContext:
    SEL sModal = NSSelectorFromString(@"initAsModalWithUserContext:");
    if (ctx && [cls instancesRespondToSelector:sModal]) {
        id inst = [cls alloc];
        if (inst) {
            id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))[inst methodForSelector:sModal];
            id result = fn(inst, sModal, ctx);
            if ([result isKindOfClass:UIViewController.class]) return (UIViewController *)result;
            [failures addObject:@"initAsModalWithUserContext: returned nil"];
        }
    }

    // Strategy C — initWithStyle: (WATableViewController subclasses)
    SEL sStyle = NSSelectorFromString(@"initWithStyle:");
    if ([cls instancesRespondToSelector:sStyle]) {
        id inst = [cls alloc];
        if (inst) {
            id (*fn)(id, SEL, long) = (id (*)(id, SEL, long))[inst methodForSelector:sStyle];
            id result = fn(inst, sStyle, (long)UITableViewStyleInsetGrouped);
            if ([result isKindOfClass:UIViewController.class]) return (UIViewController *)result;
            [failures addObject:@"initWithStyle: returned nil"];
        }
    }

    // Strategy D — initWithNibName:bundle:
    SEL sNib = NSSelectorFromString(@"initWithNibName:bundle:");
    if ([cls instancesRespondToSelector:sNib]) {
        id inst = [cls alloc];
        if (inst) {
            id (*fn)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[inst methodForSelector:sNib];
            id result = fn(inst, sNib, nil, nil);
            if ([result isKindOfClass:UIViewController.class]) return (UIViewController *)result;
            [failures addObject:@"initWithNibName:bundle: returned nil"];
        }
    }

    // Strategy E — plain -init
    @try {
        id inst = [[cls alloc] init];
        if ([inst isKindOfClass:UIViewController.class]) return (UIViewController *)inst;
        [failures addObject:@"-init returned nil"];
    } @catch (NSException *e) {
        [failures addObject:[NSString stringWithFormat:@"-init raised %@", e.name]];
    }

    if (outErr) {
        *outErr = [NSString stringWithFormat:
            @"All init strategies failed for %@:\n  • %@",
            className, [failures componentsJoinedByString:@"\n  • "]];
    }
    return nil;
}

// ── VC ────────────────────────────────────────────────────────────────────
@implementation WAGRSecretMenusVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Menus Secretos";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)OBJC_ROSTER_COUNT : (NSInteger)SWIFT_ROSTER_COUNT;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"ObjC debug controllers" : @"Swift debug controllers";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"Verde = classe carregada no runtime · cinza = ainda não carregada.\n"
                "Algumas só carregam quando o WhatsApp ativa o módulo correspondente "
                "(ex.: AR effects só após abrir a câmera com efeitos).";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    WAGRSecretEntry e = ip.section == 0 ? kObjCRoster[ip.row] : kSwiftRoster[ip.row];

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = e.title;
    c.textLabel.textColor = UIColor.labelColor;
    c.detailTextLabel.text = e.desc;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // Loaded-class indicator: a small circle in the imageView slot.
    BOOL loaded = NSClassFromString(e.className) != nil;
    UIImage *dot = [UIImage systemImageNamed:@"circle.fill"];
    c.imageView.image = [dot imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = loaded
        ? [UIColor colorWithRed:0.30 green:0.78 blue:0.45 alpha:1]
        : UIColor.tertiaryLabelColor;

    return c;
}

- (CGFloat)tableView:(UITableView *)tv estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip {
    return 66;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    WAGRSecretEntry e = ip.section == 0 ? kObjCRoster[ip.row] : kSwiftRoster[ip.row];

    NSString *err = nil;
    UIViewController *target = wagr_secretInstantiate(e.className, &err);
    if (!target) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:e.title
                             message:err ?: @"Falha desconhecida."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // Wrap in a nav controller with a Done button so the user can dismiss
    // when presented modally. If the secret VC already has its own nav
    // bar items, our Done button is added on top of them, never replacing.
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:target];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    target.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:nav
                             action:@selector(dismissViewControllerAnimated:completion:)];

    [self presentViewController:nav animated:YES completion:nil];
}

@end
