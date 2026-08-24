// WAGRMainSettingsVC.m — WATweaks settings using WhatsApp-native grouped UIKit hierarchy.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "WAGRABPropsRootVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRLogViewController.h"
#import "WAGRMainSettingsVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRSurface.h"

extern NSString *WAGRLGDiagnosticText(void);
extern NSString *WAGRDogfoodDiagnosticText(void);
extern NSString *WAGRAuraDiagnostic(void);
extern NSString *WAGRGateHooksDiagnostic(void);
extern NSString *WAGRSettingsRowsNativeDiagnosticText(void);
extern NSString *WAKeychainAccessGroupDiagnostic(void);
extern NSUInteger WAGRReinstallPersistedHooks(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRDogfoodEnsureHooksInstalled(void);
extern void WAGRLGPrefsDidChange(void);
extern void WAGRGateHooksEnsureInstalled(void);
extern NSUInteger WAGRWAABInstallHooksForAllRuntimeImages(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);

typedef NS_ENUM(NSInteger, WATCellType) {
    WATCellSwitch,
    WATCellNav,
    WATCellAction,
    WATCellDestructive,
};

@interface WATCell : NSObject
@property(nonatomic) WATCellType type;
@property(nonatomic,copy) NSString *title, *subtitle, *icon;
@property(nonatomic,copy) BOOL (^getValue)(void);
@property(nonatomic,copy) void (^onToggle)(BOOL);
@property(nonatomic,copy) void (^onTap)(UIViewController *);
@end
@implementation WATCell @end

@interface WATSection : NSObject
@property(nonatomic,copy) NSString *header, *footer;
@property(nonatomic,copy) NSArray<WATCell *> *rows;
@end
@implementation WATSection @end

static WATCell *sw(NSString *t, NSString *s, NSString *ico, BOOL(^g)(void), void(^set)(BOOL)) {
    WATCell *c=[WATCell new]; c.type=WATCellSwitch;
    c.title=t; c.subtitle=s; c.icon=ico; c.getValue=g; c.onToggle=set; return c;
}
static WATCell *nav(NSString *t, NSString *s, NSString *ico, void(^tap)(UIViewController *)) {
    WATCell *c=[WATCell new]; c.type=WATCellNav;
    c.title=t; c.subtitle=s; c.icon=ico; c.onTap=tap; return c;
}
static WATCell *act(NSString *t, NSString *s, NSString *ico, void(^tap)(UIViewController *)) {
    WATCell *c=[WATCell new]; c.type=WATCellAction;
    c.title=t; c.subtitle=s; c.icon=ico; c.onTap=tap; return c;
}
static WATCell *dtr(NSString *t, NSString *s, NSString *ico, void(^tap)(UIViewController *)) {
    WATCell *c=[WATCell new]; c.type=WATCellDestructive;
    c.title=t; c.subtitle=s; c.icon=ico; c.onTap=tap; return c;
}

static BOOL bp(NSString *k) { return [[NSUserDefaults standardUserDefaults] boolForKey:k]; }
static void setBp(NSString *k, BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:k];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static BOOL gp(NSString *k) { return WAGRGateIsSet(k) ? WAGRGateGet(k) : bp(k); }
static void setGp(NSString *k,BOOL v) { WAGRGateSet(k,v); setBp(k,v); }

static WAGRSurfaceSpec *surface(NSString *sid) {
    for (WAGRSurfaceSpec *s in [WAGRSurfaceSpec allSurfaces])
        if ([s.surfaceID isEqualToString:sid]) return s;
    return nil;
}

static void alert(UIViewController *from, NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a=[UIAlertController alertControllerWithTitle:title?:@"WATweaks"
            message:msg?:@"" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copiar" style:UIAlertActionStyleDefault
            handler:^(__unused id _){ UIPasteboard.generalPasteboard.string=msg?:@""; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *p=from; while(p.presentedViewController) p=p.presentedViewController;
        [p presentViewController:a animated:YES completion:nil];
    });
}

static WATSection *secLG(void) {
    WATSection *s=[WATSection new];
    s.header=@"Liquid Glass";
    s.rows=@[
        sw(@"Liquid Glass",@"Master — WDSLiquidGlass + todas as WAAB keys LG", @"sparkles",
           ^BOOL{ return bp(kWAGRLiquidGlassMaster); },
           ^(BOOL on){ setBp(kWAGRLiquidGlassMaster,on); WAGRLGPrefsDidChange(); }),
        sw(@"Method hooks",@"Só os hooks nos class methods de WDSLiquidGlass", @"function",
           ^BOOL{ return bp(WA_PREF_LIQUID_GLASS_METHOD_HOOKS); },
           ^(BOOL on){ setBp(WA_PREF_LIQUID_GLASS_METHOD_HOOKS,on); WAGRLGPrefsDidChange(); }),
        sw(@"NSUserDefaults overrides",@"Escreve ios_liquid_glass_* = YES em defaults", @"internaldrive",
           ^BOOL{ return bp(WA_PREF_LIQUID_GLASS_USERDEFAULTS); },
           ^(BOOL on){ setBp(WA_PREF_LIQUID_GLASS_USERDEFAULTS,on); WAGRLGPrefsDidChange(); }),
    ];
    return s;
}

static WATSection *secDogfood(void) {
    WATSection *s=[WATSection new];
    s.header=@"Dogfood / Internal";
    s.rows=@[
        sw(@"★ Employee master",@"Todos os gates abaixo de uma vez", @"person.badge.shield.checkmark.fill",
           ^BOOL{ return bp(kWAGREmployeeMaster); },
           ^(BOOL on){ setBp(kWAGREmployeeMaster,on); WAGRDogfoodEnsureHooksInstalled(); WAGRNativeDevMenuEnsureHooksInstalled(); }),
        sw(@"isInternalUser",@"WAServerProperties +isInternalUser (class method)", @"person.fill.checkmark",
           ^BOOL{ return gp(kWAGRDogfoodGateInternalUser); },
           ^(BOOL on){ setGp(kWAGRDogfoodGateInternalUser,on); WAGRDogfoodEnsureHooksInstalled(); }),
        sw(@"isMetaEmployeeOrInternalTester",@"Gate de acesso a features internas Meta", @"building.2.fill",
           ^BOOL{ return gp(kWAGRDogfoodGateMetaEmployee); },
           ^(BOOL on){ setGp(kWAGRDogfoodGateMetaEmployee,on); WAGRDogfoodEnsureHooksInstalled(); }),
        sw(@"isInternalMaster",@"watweak_bundle_internal_master — modo interno geral", @"building.columns.fill",
           ^BOOL{ return bp(kWAGRInternalMaster); },
           ^(BOOL on){ setBp(kWAGRInternalMaster,on); }),
        sw(@"Debug menu nativo",@"isDebugMenuAllowed + isDebugMenuShortcutEnabled", @"ladybug.fill",
           ^BOOL{ return bp(kWAGRDebugMenuNative); },
           ^(BOOL on){ setBp(kWAGRDebugMenuNative,on); WAGRNativeDevMenuEnsureHooksInstalled(); }),
    ];
    return s;
}

static WATSection *secAura(void) {
    WATSection *s=[WATSection new];
    s.header=@"WA Plus / Aura";
    s.rows=@[
        sw(@"★ Aura Simulation",@"Master — aura_enabled + aura_subscription_simulation", @"crown.fill",
           ^BOOL{ return bp(kWAGRAuraSimulation); },
           ^(BOOL on){
               setBp(kWAGRAuraSimulation,on);
               for(NSString*k in @[@"aura_enabled",@"aura_settings_row_enabled",
                                   @"aura_subscription_simulation_enabled",@"aura_app_icon_enabled",
                                   @"aura_app_themes_enabled",@"aura_ringtones_enabled",
                                   @"aura_stickers_enabled",@"aura_enhanced_lists_enabled",
                                   @"aura_pinned_chats_enabled"])
                   on ? WAGRGateSet(k,YES) : WAGRGateClear(k);
               WAGRAuraEnsureHooksInstalled();
           }),
        sw(@"aura_enabled",@"Gate principal da UI do Aura", @"star.fill",
           ^BOOL{ return gp(@"aura_enabled"); },
           ^(BOOL on){ setGp(@"aura_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_subscription_simulation_enabled",@"Simula assinatura — unlock de UI local", @"creditcard.fill",
           ^BOOL{ return gp(@"aura_subscription_simulation_enabled"); },
           ^(BOOL on){ setGp(@"aura_subscription_simulation_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_app_themes_enabled",@"Temas do aplicativo", @"paintpalette.fill",
           ^BOOL{ return gp(@"aura_app_themes_enabled"); },
           ^(BOOL on){ setGp(@"aura_app_themes_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_app_icon_enabled",@"Ícones do aplicativo", @"app.badge.fill",
           ^BOOL{ return gp(@"aura_app_icon_enabled"); },
           ^(BOOL on){ setGp(@"aura_app_icon_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_ringtones_enabled",@"Toques personalizados", @"music.note",
           ^BOOL{ return gp(@"aura_ringtones_enabled"); },
           ^(BOOL on){ setGp(@"aura_ringtones_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_stickers_enabled",@"Stickers premium Aura", @"face.smiling.fill",
           ^BOOL{ return gp(@"aura_stickers_enabled"); },
           ^(BOOL on){ setGp(@"aura_stickers_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_enhanced_lists_enabled",@"Listas aprimoradas", @"list.bullet.indent",
           ^BOOL{ return gp(@"aura_enhanced_lists_enabled"); },
           ^(BOOL on){ setGp(@"aura_enhanced_lists_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
        sw(@"aura_pinned_chats_enabled",@"Chats fixados extras", @"pin.fill",
           ^BOOL{ return gp(@"aura_pinned_chats_enabled"); },
           ^(BOOL on){ setGp(@"aura_pinned_chats_enabled",on); WAGRAuraEnsureHooksInstalled(); }),
    ];
    return s;
}

static WATSection *secWAAB(void) {
    WATSection *s=[WATSection new];
    s.header=@"WAABProperties";
    s.rows=@[
        nav(@"AB Props",@"Runtime, cache account-scoped, fetch e export", @"switch.2",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRABPropsRootVC new] animated:YES];
            }),
    ];
    return s;
}

static WATSection *secRuntime(void) {
    WATSection *s=[WATSection new];
    s.header=@"Runtime Gates";
    s.rows=@[
        nav(@"WhatsApp Executable",@"Gates e classes do executável principal", @"app.dashed",
            ^(UIViewController *from){
                WAGRSurfaceSpec *sp=surface(@"exec");
                if(sp) [from.navigationController pushViewController:[[WAGRSurfaceBrowserVC alloc] initWithSpec:sp] animated:YES];
                else alert(from,@"Runtime",@"Surface 'exec' não encontrada.");
            }),
        nav(@"SharedModules",@"Gates e classes do framework", @"shippingbox.fill",
            ^(UIViewController *from){
                WAGRSurfaceSpec *sp=surface(@"sharedmodules");
                if(sp) [from.navigationController pushViewController:[[WAGRSurfaceBrowserVC alloc] initWithSpec:sp] animated:YES];
                else alert(from,@"Runtime",@"Surface 'sharedmodules' não encontrada.");
            }),
    ];
    return s;
}

static WATSection *secTools(void) {
    WATSection *s=[WATSection new];
    s.header=@"Ferramentas";
    s.rows=@[
        nav(@"Logs",@"Log interno da sessão atual", @"list.bullet.rectangle.portrait.fill",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
            }),
        act(@"Diagnóstico completo",@"GateStore · LG · Aura · Dogfood · Settings row · Keychain",
            @"doc.text.magnifyingglass",
            ^(UIViewController *from){
                NSString *msg=[NSString stringWithFormat:
                    @"[LiquidGlass]\n%@\n\n[Aura]\n%@\n\n[Dogfood]\n%@\n\n[GateStore]\n%@\n\n[Settings row]\n%@\n\n[Keychain]\n%@",
                    WAGRLGDiagnosticText()?:@"n/a", WAGRAuraDiagnostic()?:@"n/a",
                    WAGRDogfoodDiagnosticText()?:@"n/a", WAGRGateStoreDiagnostic()?:@"n/a",
                    WAGRSettingsRowsNativeDiagnosticText()?:@"n/a", WAKeychainAccessGroupDiagnostic()?:@"n/a"];
                alert(from,@"Diagnóstico",msg);
            }),
        dtr(@"Reset WATweaks",@"Remove todos os overrides watweak_* e índices runtime", @"trash.fill",
            ^(UIViewController *from){
                UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Reset"
                    message:@"Remove todos os overrides watweak_*.\nReinicie o WA depois."
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _){
                    NSUInteger n=WAGRGateClearAll();
                    NSUserDefaults *ud=NSUserDefaults.standardUserDefaults;
                    for(NSString*k in ud.dictionaryRepresentation.allKeys)
                        if([k hasPrefix:@"watweak_"]||[k hasPrefix:@"watweak."]){[ud removeObjectForKey:k];n++;}
                    [ud synchronize];
                    NSLog(@"[WATweaks] reset removed %lu managed keys", (unsigned long)n);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),
                                   dispatch_get_main_queue(),^{exit(0);});
                }]];
                [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
                [from presentViewController:a animated:YES completion:nil];
            }),
        dtr(@"Reiniciar WhatsApp",@"Fecha o app — descarrega hooks desta sessão", @"power",
            ^(__unused UIViewController *from){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),
                               dispatch_get_main_queue(),^{exit(0);});
            }),
    ];
    return s;
}

@implementation WAGRMainSettingsVC {
    NSArray<WATSection *> *_sections;
}

- (instancetype)init {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title=@"WATweaks";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight=60.0;
    self.tableView.rowHeight=60.0;
    self.tableView.separatorInset=UIEdgeInsetsMake(0, 56.0, 0, 16.0);
    if (@available(iOS 15.0,*)) self.tableView.sectionHeaderTopPadding=0.0;

    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(done)];

    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone
        target:self action:@selector(applyAllHooks)];

    [self rebuildSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuildSections];
    [self.tableView reloadData];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)applyAllHooks {
    WAGRGateHooksEnsureInstalled();
    NSUInteger waab=WAGRWAABInstallHooksForAllRuntimeImages();
    WAGRAuraEnsureHooksInstalled();
    WAGRDogfoodEnsureHooksInstalled();
    WAGRLGPrefsDidChange();
    NSUInteger n=WAGRReinstallPersistedHooks();
    NSString *msg=[NSString stringWithFormat:
        @"%lu hooks/overrides reaplicados.\nWAAB central hooks: %lu\n\nGateStore overrides ativos: %lu",
        (unsigned long)n,(unsigned long)waab,(unsigned long)WAGRGateAllOverrides().count];
    alert(self,@"Aplicar",msg);
    [self.tableView reloadData];
}

- (void)rebuildSections {
    _sections=@[secLG(),secDogfood(),secAura(),secWAAB(),secRuntime(),secTools()];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tv {
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return (NSInteger)_sections[(NSUInteger)sec].rows.count;
}

// Section names remain model metadata for the Dogfood patch, but are not drawn.
// WhatsApp Settings communicates grouping through inset cards and whitespace.
- (NSString *)tableView:(__unused UITableView *)tv titleForHeaderInSection:(__unused NSInteger)sec { return nil; }
- (NSString *)tableView:(__unused UITableView *)tv titleForFooterInSection:(__unused NSInteger)sec { return nil; }

- (CGFloat)tableView:(__unused UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 12.0 : 28.0;
}

- (CGFloat)tableView:(__unused UITableView *)tv heightForFooterInSection:(__unused NSInteger)section {
    return 8.0;
}

- (CGFloat)tableView:(__unused UITableView *)tv heightForRowAtIndexPath:(__unused NSIndexPath *)ip {
    return 60.0;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    WATCell *row=_sections[(NSUInteger)ip.section].rows[(NSUInteger)ip.row];
    NSString *rid=[NSString stringWithFormat:@"WATNative-%ld",(long)row.type];
    UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:rid];
    if(!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];

    WAGRMenuApplyCellStyle(cell, ip.row, row.title);
    cell.textLabel.text=row.title;
    cell.textLabel.font=WAGRMenuTitleFont();
    cell.textLabel.numberOfLines=1;
    cell.textLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    cell.imageView.image=WAGRMenuSymbol(row.icon, UIColor.whiteColor);
    cell.imageView.tintColor=UIColor.whiteColor;
    cell.accessoryView=nil;
    cell.accessoryType=UITableViewCellAccessoryNone;
    cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor=WAGRMenuTextColor();

    switch(row.type){
        case WATCellSwitch:{
            UISwitch *s=[[UISwitch alloc]init];
            s.on=row.getValue?row.getValue():NO;
            [s addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            objc_setAssociatedObject(s,"wrow",row,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.accessoryView=s;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
            break;
        }
        case WATCellNav:
            cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
            break;
        case WATCellDestructive:
            cell.textLabel.textColor=UIColor.systemRedColor;
            break;
        case WATCellAction:
            break;
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    WATCell *row=objc_getAssociatedObject(sender,"wrow");
    if(row.onToggle) row.onToggle(sender.isOn);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    WATCell *row=_sections[(NSUInteger)ip.section].rows[(NSUInteger)ip.row];
    if(row.onTap) row.onTap(self);
}

@end
