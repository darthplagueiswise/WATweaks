// WAGRSecretMenusVC.m  (rewritten)
// ─────────────────────────────────────────────────────────────────────────────
// Why this VC was reshaped
// ────────────────────────
// The previous version of this file tried to instantiate WhatsApp's hidden
// Debug view controllers directly via `-initWithUserContext:` and similar.
// Static analysis of the Swift Debug VCs (and the EXC_BREAKPOINT crash
// report from a 26.19.10 build) showed those controllers expect a fully-
// wired Swift environment around them — `WAIsLiquidGlassEnabled` and
// `FBAnalyticsDeleteLegacyLogPathIfExists` get called inside their init
// and assert when the surrounding state is missing. Several controllers
// also crash on dismissal because their Swift teardown reads ivars
// that were never populated.
//
// The right model for users is not "instantiate this controller" but
// "make the app believe you are an internal/employee user". When that
// belief lands, the native Settings → Developer / Subscriptions screens
// expose their internal cells through WhatsApp's own navigation, which
// guarantees every cell is wired correctly and nothing crashes.
//
// What this VC now does
// ─────────────────────
// 1) Master toggles for the two upstream concepts:
//    • Internal/Employee mode → flips WAServerProperties +isInternalUser
//      override key (kWAGREmployeeMaster) AND the granular dogfood gate
//      (kWAGRDogfoodGateInternalUser). That single class method is the
//      confirmed upstream gate for every is-internal check that goes
//      through the ObjC bridge.
//    • Aura simulation mode → flips kWAGRAuraSimulationMaster, which is
//      the shared "is Aura on?" source of truth read by both WAAuraHooks
//      and WAGRAccountEligibilityHooks. That is what unlocks the
//      Subscriptions / WA Plus Settings row natively.
// 2) Live diagnostic — one row per hook subsystem showing whether it is
//    actually installed and whether its master is currently ON.
// 3) Informational list of the ~32 debug VCs found in the binary, with a
//    green/grey indicator for "loaded at this moment". No tap actions.
// 4) A short "como usar" footer with the precise sequence.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRSecretMenusVC.h"
#import "../WAGramPrefix.h"
#import <objc/runtime.h>

extern NSString *WAGRDogfoodDiagnosticText(void);
extern NSString *WAGRAccountEligibilityDiagnostic(void);
extern NSString *WAGRAuraDiagnostic(void);
extern NSString *WAGRWAABDiagnosticText(void);
extern NSString *WAGRNativeDevMenuDiagnosticText(void);
extern NSString *WAGRSettingsRowsNativeDiagnosticText(void);
extern NSString *WAGRMeTabDiagnostic(void);

typedef NS_ENUM(NSInteger, WAGRSecretSection) {
    WAGRSecretSectionMasters = 0,
    WAGRSecretSectionDiagnostic,
    WAGRSecretSectionList,
    WAGRSecretSectionHowTo,
    WAGRSecretSectionCount,
};

// ─── Master toggles ───────────────────────────────────────────────────────
// Each master flips a set of underlying pref keys atomically. Defining
// them as plain dictionaries keeps the row handler dumb and lets us add
// or remove keys later without touching switch handler logic.
static NSArray<NSDictionary *> *WAGRMasterToggles(void) {
    return @[
        @{ @"title":    @"Modo Internal / Employee",
           @"subtitle": @"WAServerProperties +isInternalUser → YES. Libera Settings → Developer e fluxos internos no próximo launch.",
           @"icon":     @"person.crop.circle.badge.checkmark",
           @"keys":     @[ kWAGREmployeeMaster,
                           kWAGRDogfoodGateInternalUser,
                           kWAGRDogfoodGateMetaEmployee,
                           kWAGRDogfoodGateMetaEmployeeSnake,
                           kWAGRDogfoodGateGraphQLEmpC1,
                           kWAGRInternalMaster,
                           kWAGRDebugMode ] },
        @{ @"title":    @"Simulação Aura / WA Plus",
           @"subtitle": @"WAAuraGating + WAAccountEligibility -isEligibleForSubscriptions → YES. Faz aparecer a row Subscriptions em Settings.",
           @"icon":     @"sparkles",
           @"keys":     @[ @"wagr_aura_simulation_enabled" ] },
        // Modo Me-Tab: liga TODOS os gates do Contacts Hub + About Evolve +
        // Waffle de uma vez. As gates são instance methods ObjC normais
        // (não Swift puro), então MSHookMessageEx funciona limpinho.
        @{ @"title":    @"Modo Me-Tab / Contacts Hub / About Evolve",
           @"subtitle": @"Liga isMeTabEnabled, isEvolveAboutM1Enabled, isMeTabProfilePictureEntrypointEnabled, shouldShowRecentlyOnlineSuggestedContacts e isWaffleSwitchingEnabled.",
           @"icon":     @"person.2.crop.square.stack.fill",
           @"keys":     @[ @"wagr_metab_master_enabled" ] },
    ];
}

static BOOL WAGRMasterIsOn(NSDictionary *toggle) {
    for (NSString *k in (NSArray *)toggle[@"keys"]) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:k]) return YES;
    }
    return NO;
}

static void WAGRMasterApply(NSDictionary *toggle, BOOL on) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *k in (NSArray *)toggle[@"keys"]) {
        if (on) [ud setBool:YES forKey:k];
        else    [ud removeObjectForKey:k];
    }
    [ud synchronize];
    NSLog(@"[WATweaks][SecretPanel] %@ master toggle → %@",
          toggle[@"title"], on ? @"ON" : @"OFF");
}

// ─── Diagnostic rows ──────────────────────────────────────────────────────
static NSArray<NSDictionary *> *WAGRDiagnosticRows(void) {
    return @[
        @{ @"name": @"Employee / isInternalUser hook", @"fn": @"dogfood" },
        @{ @"name": @"WAAccountEligibility hook",       @"fn": @"elig" },
        @{ @"name": @"Aura gating hook",                @"fn": @"aura" },
        @{ @"name": @"Me-Tab / Contacts Hub hook",      @"fn": @"metab" },
        @{ @"name": @"WAABProperties observer",         @"fn": @"waab" },
        @{ @"name": @"Native dev-menu hook",            @"fn": @"devmenu" },
        @{ @"name": @"Settings rows native hook",       @"fn": @"settings" },
    ];
}

static NSString *WAGRDiagnosticText(NSString *fn) {
    if ([fn isEqualToString:@"dogfood"])  return WAGRDogfoodDiagnosticText();
    if ([fn isEqualToString:@"elig"])     return WAGRAccountEligibilityDiagnostic();
    if ([fn isEqualToString:@"aura"])     return WAGRAuraDiagnostic();
    if ([fn isEqualToString:@"metab"])    return WAGRMeTabDiagnostic();
    if ([fn isEqualToString:@"waab"])     return WAGRWAABDiagnosticText();
    if ([fn isEqualToString:@"devmenu"])  return WAGRNativeDevMenuDiagnosticText();
    if ([fn isEqualToString:@"settings"]) return WAGRSettingsRowsNativeDiagnosticText();
    return @"(no diagnostic)";
}

// ─── Debug VC roster (informational only) ─────────────────────────────────
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

// ─── VC ───────────────────────────────────────────────────────────────────
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return WAGRSecretSectionCount;
}

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
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != WAGRSecretSectionDiagnostic) return;

    NSDictionary *d = WAGRDiagnosticRows()[ip.row];
    NSString *full = WAGRDiagnosticText(d[@"fn"]) ?: @"(no diagnostic)";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:d[@"name"]
                         message:full
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleMaster:(UISwitch *)sw {
    NSDictionary *t = WAGRMasterToggles()[sw.tag];
    WAGRMasterApply(t, sw.on);
    [self.tableView reloadData];
}

@end
