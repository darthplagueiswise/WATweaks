// WAGRSecretMenusVC.m  (refactor — schema v2)
// ─────────────────────────────────────────────────────────────────────────────
// Why this VC was reshaped
// ────────────────────────
// The previous version of this file tried to instantiate WhatsApp's hidden
// Debug view controllers directly via `-initWithUserContext:` and similar.
// Static analysis of the Swift Debug VCs (and the EXC_BREAKPOINT crash
// report from a 26.19.10 build) showed those controllers expect a fully-
// wired Swift environment around them. Several controllers also crash on
// dismissal because their Swift teardown reads ivars that were never
// populated.
//
// The right model for users is not "instantiate this controller" but
// "make the app believe you are an internal/employee user". When that
// belief lands, the native Settings → Developer / Subscriptions screens
// expose their internal cells through WhatsApp's own navigation, which
// guarantees every cell is wired correctly and nothing crashes.
//
// Schema-v2 alignment
// ───────────────────
// Every runtime/WAAB override now goes through WAGRGateStore.h. The
// master toggle for "Internal mode" sets the *master prefs* (which the
// dogfood hook reads directly) and additionally writes selector-name
// overrides (so the runtime hook also fires). The runtime hook bootstrap
// is reinstalled at the end of every master flip in case the toggle is
// the first thing the user does.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRSecretMenusVC.h"
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import <objc/runtime.h>

// ── External symbols (resolved at link time across files) ────────────────────
extern NSString *WAGRDogfoodDiagnosticText(void);
extern NSString *WAGRAccountEligibilityDiagnostic(void);
extern NSString *WAGRAuraNavigationDiagnostic(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern NSString *WAGRNativeDevMenuDiagnosticText(void);
extern NSString *WAGRSettingsRowsNativeDiagnosticText(void);
extern void WAGRGateHooksEnsureInstalled(void);
extern void WAGRDogfoodEnsureHooksInstalled(void);
extern void WAGRAuraEnsureNavigationHooksInstalled(void);
extern void WAGRAuraActivateAllFlags(void);
extern void WAGRAuraDeactivateAllFlags(void);
extern void WAGRAccountEligibilityEnsureHooksInstalled(void);
extern BOOL WAGRGateInstallHookForSelector(NSString *className,
                                            NSString *selectorName,
                                            BOOL isClassMethod);

// ── Runtime override item (a (className, selector, isClassMethod) tuple) ─────
// We still describe master-toggle runtime overrides as plain dictionaries
// for clarity. The persisted key, however, is now just the selector name —
// the (class, isClassMethod) information lives only in code, used to call
// WAGRGateInstallHookForSelector when we set the override ON.
static NSArray<NSDictionary *> *WAGRSecretRuntimeOverrides(NSArray<NSDictionary *> *items) {
    return items ?: @[];
}

static void WAGRSecretApplyRuntimeOverride(NSDictionary *item, BOOL on) {
    NSString *className = item[@"class"];
    NSString *selector  = item[@"selector"];
    if (!selector.length) return;
    BOOL isClassMethod = [item[@"classMethod"] boolValue];

    if (on) {
        WAGRGateSet(selector, YES);
        if (className.length) {
            (void)WAGRGateInstallHookForSelector(className, selector, isClassMethod);
        }
    } else {
        WAGRGateClear(selector);
    }
}

// ── Me-Tab / Contacts Hub bundle ─────────────────────────────────────────────
static NSArray<NSString *> *WAGRSecretMeTabWAABFlags(void) {
    return @[
        @"me_tab_status_creation_enabled",
        @"me_tab_self_status_viewing_enabled",
        @"me_tab_settings_header_enabled",
        @"me_tab_settings_title_enabled",
        @"me_tab_profile_picture_entrypoint_enabled",
        @"me_tab_profile_picture_abprop_sync_enabled",
        @"wa_account_switcher_settings_me_tab",
        @"xfam_lg_switcher_m2_me_tab_enabled",
        @"ios_me_tab_new_user_checklist_enabled",
        @"ios_me_tab_share_updates_enabled",
        @"ios_me_tab_username_findability_enabled",
        @"ios_contacts_surface_is_enabled",
        @"ios_contactshub_presence_status",
        @"shouldShowRecentlyOnlineSuggestedContacts",
        @"recently_online_contacts_enabled",
        @"contacts_hub_enabled",
        @"contacts_hub_recently_online_enabled",
        @"evolve_about_m1_enabled"
    ];
}

static NSArray<NSDictionary *> *WAGRSecretMeTabRuntimeOverrides(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray<NSString *> *classes = @[
        @"WAContext", @"WAContextMain",
        @"WAABProperties", @"FOAWAABPropertiesImpl"
    ];
    NSArray<NSString *> *selectors = @[
        @"isMeTabEnabled",
        @"isEvolveAboutM1Enabled",
        @"isMeTabProfilePictureEntrypointEnabled",
        @"shouldShowRecentlyOnlineSuggestedContacts",
        @"isWaffleSwitchingEnabled",
        @"isContactsSurfaceEnabled",
        @"isContactsHubEnabled",
        @"isRecentlyOnlineContactsEnabled",
        @"isUsernameExperienceEnabled",
        @"shouldShowUsernameRowOnCompanion"
    ];
    for (NSString *cls in classes) {
        for (NSString *sel in selectors) {
            [out addObject:@{@"class": cls, @"selector": sel, @"classMethod": @NO}];
        }
    }
    return out;
}

// ── Internal / isInternalUser override bundle ────────────────────────────────
static NSArray<NSDictionary *> *WAGRSecretInternalRuntimeOverrides(void) {
    return @[
        @{@"class": @"WAServerProperties", @"selector": @"isInternalUser", @"classMethod": @YES},
        @{@"class": @"WAContextMain",      @"selector": @"isInternalUser", @"classMethod": @NO},
        @{@"class": @"WAContext",          @"selector": @"isInternalUser", @"classMethod": @NO}
    ];
}

// ── Me-Tab diagnostic ────────────────────────────────────────────────────────
static NSString *WAGRSecretMeTabDiagnosticText(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *flag in WAGRSecretMeTabWAABFlags()) {
        NSString *state;
        if (!WAGRGateIsSet(flag)) state = @"unset";
        else state = WAGRGateGet(flag) ? @"ON" : @"OFF";
        [lines addObject:[NSString stringWithFormat:@"%@=%@", flag, state]];
    }

    NSUInteger runtimeOn = 0;
    NSUInteger runtimeTotal = 0;
    for (NSDictionary *item in WAGRSecretMeTabRuntimeOverrides()) {
        runtimeTotal++;
        NSString *sel = item[@"selector"];
        if (WAGRGateIsSet(sel) && WAGRGateGet(sel)) runtimeOn++;
    }
    [lines addObject:[NSString stringWithFormat:@"runtimeOverrides=%lu/%lu",
                      (unsigned long)runtimeOn, (unsigned long)runtimeTotal]];
    return [lines componentsJoinedByString:@"\n"];
}

typedef NS_ENUM(NSInteger, WAGRSecretSection) {
    WAGRSecretSectionMasters = 0,
    WAGRSecretSectionDiagnostic,
    WAGRSecretSectionList,
    WAGRSecretSectionHowTo,
    WAGRSecretSectionCount,
};

// ── Master toggles ───────────────────────────────────────────────────────────
// Each master flips a set of underlying pref keys atomically. masterKeys are
// plain NSUserDefaults bool keys (wagr_*, wagr.dogfood.*). waabOn/waabOff and
// runtimeOn write schema-v2 gate overrides (selector-name keys).
static NSArray<NSDictionary *> *WAGRMasterToggles(void) {
    return @[
        @{ @"title":    @"Modo Internal / Employee",
           @"subtitle": @"Liga prefs masters + override runtime de WAServerProperties/WAContext isInternalUser.",
           @"icon":     @"person.crop.circle.badge.checkmark",
           @"masterKeys": @[ kWAGREmployeeMaster,
                             kWAGRDogfoodGateInternalUser,
                             kWAGRDogfoodGateMetaEmployee,
                             kWAGRDogfoodGateMetaEmployeeSnake,
                             kWAGRDogfoodGateGraphQLEmpC1,
                             kWAGRInternalMaster,
                             kWAGRDebugMode ],
           @"runtimeOn": WAGRSecretInternalRuntimeOverrides() },

        @{ @"title":    @"Simulação Aura / WA Plus",
           @"subtitle": @"Aplica o bundle Aura via WAGRAuraActivateAllFlags/DeactivateAllFlags.",
           @"icon":     @"sparkles",
           @"masterKeys": @[ kWAGRAuraSimulation ],
           @"action":   @"aura" },

        @{ @"title":    @"Modo Me-Tab / Contacts Hub / About Evolve",
           @"subtitle": @"Liga WAAB flags tab_me/about/contacts e overrides runtime em WAContext/WAContextMain/WAABProperties.",
           @"icon":     @"person.2.crop.square.stack.fill",
           @"masterKeys": @[ @"wagr_metab_master_enabled" ],
           @"waabOn":   WAGRSecretMeTabWAABFlags(),
           @"runtimeOn": WAGRSecretMeTabRuntimeOverrides() },
    ];
}

static BOOL WAGRMasterIsOn(NSDictionary *toggle) {
    for (NSString *k in (NSArray *)toggle[@"masterKeys"]) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:k]) return YES;
    }
    for (NSString *flag in (NSArray *)toggle[@"waabOn"]) {
        if (WAGRGateIsSet(flag) && WAGRGateGet(flag)) return YES;
    }
    for (NSString *flag in (NSArray *)toggle[@"waabOff"]) {
        if (WAGRGateIsSet(flag) && !WAGRGateGet(flag)) return YES;
    }
    for (NSDictionary *item in WAGRSecretRuntimeOverrides(toggle[@"runtimeOn"])) {
        NSString *sel = item[@"selector"];
        if (WAGRGateIsSet(sel) && WAGRGateGet(sel)) return YES;
    }
    return NO;
}

static void WAGRMasterApply(NSDictionary *toggle, BOOL on) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    for (NSString *k in (NSArray *)toggle[@"masterKeys"]) {
        if (on) [ud setBool:YES forKey:k];
        else    [ud removeObjectForKey:k];
    }

    NSString *action = toggle[@"action"];
    if ([action isEqualToString:@"aura"]) {
        if (on) WAGRAuraActivateAllFlags();
        else    WAGRAuraDeactivateAllFlags();
    }

    for (NSString *flag in (NSArray *)toggle[@"waabOn"]) {
        if (on) WAGRGateSet(flag, YES); else WAGRGateClear(flag);
    }
    for (NSString *flag in (NSArray *)toggle[@"waabOff"]) {
        if (on) WAGRGateSet(flag, NO); else WAGRGateClear(flag);
    }
    for (NSDictionary *item in WAGRSecretRuntimeOverrides(toggle[@"runtimeOn"])) {
        WAGRSecretApplyRuntimeOverride(item, on);
    }

    [ud synchronize];

    WAGRGateHooksEnsureInstalled();
    WAGRDogfoodEnsureHooksInstalled();
    WAGRAuraEnsureNavigationHooksInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();

    NSLog(@"[WATweaks][SecretPanel] %@ master toggle → %@",
          toggle[@"title"], on ? @"ON" : @"OFF");
}

// ── Diagnostic rows ──────────────────────────────────────────────────────────
static NSArray<NSDictionary *> *WAGRDiagnosticRows(void) {
    return @[
        @{ @"name": @"Employee / isInternalUser hook", @"fn": @"dogfood" },
        @{ @"name": @"WAAccountEligibility hook",       @"fn": @"elig" },
        @{ @"name": @"Aura navigation hook",            @"fn": @"aura" },
        @{ @"name": @"Me-Tab / Contacts Hub",           @"fn": @"metab" },
        @{ @"name": @"Gate hooks (storage + bootstrap)",@"fn": @"gates" },
        @{ @"name": @"Native dev-menu hook",            @"fn": @"devmenu" },
        @{ @"name": @"Settings rows native hook",       @"fn": @"settings" },
    ];
}

static NSString *WAGRDiagnosticText(NSString *fn) {
    if ([fn isEqualToString:@"dogfood"])  return WAGRDogfoodDiagnosticText();
    if ([fn isEqualToString:@"elig"])     return WAGRAccountEligibilityDiagnostic();
    if ([fn isEqualToString:@"aura"])     return WAGRAuraNavigationDiagnostic();
    if ([fn isEqualToString:@"metab"])    return WAGRSecretMeTabDiagnosticText();
    if ([fn isEqualToString:@"gates"])    return WAGRGateHooksDiagnostic();
    if ([fn isEqualToString:@"devmenu"])  return WAGRNativeDevMenuDiagnosticText();
    if ([fn isEqualToString:@"settings"]) return WAGRSettingsRowsNativeDiagnosticText();
    return @"(no diagnostic)";
}

// ── Debug VC roster (informational only) ─────────────────────────────────────
static NSArray<NSString *> *WAGRSecretVCRoster(void) {
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
        @"_TtC13WAGraphQLAuth41GraphQLAuthManagerDebugToolViewController",
    ];
}

// ─── VC ─────────────────────────────────────────────────────────────────────
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return WAGRSecretSectionCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch ((WAGRSecretSection)s) {
        case WAGRSecretSectionMasters:    return (NSInteger)WAGRMasterToggles().count;
        case WAGRSecretSectionDiagnostic: return (NSInteger)WAGRDiagnosticRows().count;
        case WAGRSecretSectionList:       return (NSInteger)WAGRSecretVCRoster().count;
        case WAGRSecretSectionHowTo:      return 1;
        case WAGRSecretSectionCount:      return 0;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch ((WAGRSecretSection)s) {
        case WAGRSecretSectionMasters:    return @"ATIVAR MASTER";
        case WAGRSecretSectionDiagnostic: return @"DIAGNÓSTICO";
        case WAGRSecretSectionList:       return @"CONTROLLERS DEBUG NO BINÁRIO";
        case WAGRSecretSectionHowTo:      return @"COMO USAR";
        case WAGRSecretSectionCount:      return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == WAGRSecretSectionList) {
        return @"Apenas informativo. Verde = classe carregada no runtime agora; cinza = ainda não carregada. Não abrimos por tap porque os Swift Debug VCs esperam ambiente do WhatsApp totalmente montado e dão SIGTRAP se forem instanciados por fora.";
    }
    if (s == WAGRSecretSectionMasters) {
        return @"Ligue → restarte o WhatsApp → abra Settings → Developer NATIVAMENTE pelo app. As células internas funcionam porque o WhatsApp monta o Swift environment.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];

    switch ((WAGRSecretSection)ip.section) {
        case WAGRSecretSectionMasters: {
            NSDictionary *t = WAGRMasterToggles()[ip.row];
            c.textLabel.text = t[@"title"];
            c.textLabel.textColor = UIColor.labelColor;
            c.detailTextLabel.text = t[@"subtitle"];
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            c.detailTextLabel.numberOfLines = 0;
            UIImage *icon = [UIImage systemImageNamed:t[@"icon"]];
            c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            c.imageView.tintColor = UIColor.systemOrangeColor;

            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = WAGRMasterIsOn(t);
            sw.tag = ip.row;
            [sw addTarget:self action:@selector(toggleMaster:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case WAGRSecretSectionDiagnostic: {
            NSDictionary *d = WAGRDiagnosticRows()[ip.row];
            c.textLabel.text = d[@"name"];
            c.textLabel.textColor = UIColor.labelColor;
            NSString *full = WAGRDiagnosticText(d[@"fn"]) ?: @"";
            NSString *firstLine = [[full componentsSeparatedByString:@"\n"] firstObject] ?: @"";
            c.detailTextLabel.text = firstLine;
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            UIImage *icon = [UIImage systemImageNamed:@"stethoscope"];
            c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            c.imageView.tintColor = UIColor.systemBlueColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case WAGRSecretSectionList: {
            NSString *cls = WAGRSecretVCRoster()[ip.row];
            c.textLabel.text = cls;
            c.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
            c.textLabel.textColor = UIColor.labelColor;
            c.textLabel.numberOfLines = 0;
            BOOL loaded = NSClassFromString(cls) != nil;
            UIImage *dot = [UIImage systemImageNamed:@"circle.fill"];
            c.imageView.image = [dot imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            c.imageView.tintColor = loaded
                ? [UIColor colorWithRed:0.30 green:0.78 blue:0.45 alpha:1]
                : UIColor.tertiaryLabelColor;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case WAGRSecretSectionHowTo: {
            c.textLabel.text = @"Sequência recomendada";
            c.textLabel.textColor = UIColor.labelColor;
            c.detailTextLabel.text = @"1. Ligue \"Modo Internal\" e/ou \"Simulação Aura\" acima.\n"
                                      "2. Force-quit e reabra o WhatsApp uma vez.\n"
                                      "3. Abra Configurações no app. A row Developer aparece abaixo do bloco Meta; Subscriptions / WA Plus aparece com Aura ligado.\n"
                                      "4. Toque NATIVAMENTE — não use o launcher modal do WATweaks para essas células.";
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            c.detailTextLabel.numberOfLines = 0;
            UIImage *icon = [UIImage systemImageNamed:@"list.number"];
            c.imageView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            c.imageView.tintColor = UIColor.systemTealColor;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case WAGRSecretSectionCount: break;
    }
    return c;
}

- (CGFloat)tableView:(UITableView *)tv estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip { return 66; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewAutomaticDimension; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != WAGRSecretSectionDiagnostic) return;

    NSDictionary *d = WAGRDiagnosticRows()[ip.row];
    NSString *full = WAGRDiagnosticText(d[@"fn"]) ?: @"(no diagnostic)";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:d[@"name"]
                         message:full
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused id _) { UIPasteboard.generalPasteboard.string = full; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleMaster:(UISwitch *)sw {
    NSDictionary *t = WAGRMasterToggles()[sw.tag];
    WAGRMasterApply(t, sw.on);
    [self.tableView reloadData];
}

@end
