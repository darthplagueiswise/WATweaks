// WAGRMainSettingsVC.m — compact root menu. Feature gates live in canonical submenus.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGRGateStore.h"
#import "WAGRABPropsRootVC.h"
#import "WAGRFeatureBundlesVC.h"
#import "WAGRMobileConfigExportVC.h"
#import "WAGRRuntimeGatesVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "WAGRLogViewController.h"
#import "WAGRDebugDiagnosticsVC.h"
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
extern id WAGRCurrentUserContext(void);

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

static WATSection *secFeatures(void) {
    WATSection *s=[WATSection new];
    s.header=@"Features / Experimentos";
    s.rows=@[
        nav(@"Features / Experimentos",
            @"Descoberta live por versão · sem lista fixa de selectors/AB IDs",
            @"slider.horizontal.3",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRFeatureBundlesVC new] animated:YES];
            }),
    ];
    return s;
}

static WATSection *secWAAB(void) {
    WATSection *s=[WATSection new];
    s.header=@"WAABProperties";
    s.rows=@[
        nav(@"AB Props",@"ABProperties Browser · snapshot account-scoped · fetch", @"switch.2",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRABPropsRootVC new] animated:YES];
            }),
        nav(@"MobileConfig / arquivos",@"id_name_mapping.json · mc_overrides.json · crosswalk UserSession", @"doc.badge.gearshape",
            ^(UIViewController *from){
                WAGRMobileConfigExportVC *vc=[[WAGRMobileConfigExportVC alloc] initWithUserContext:WAGRCurrentUserContext()];
                [from.navigationController pushViewController:vc animated:YES];
            }),
    ];
    return s;
}

static WATSection *secRuntime(void) {
    WATSection *s=[WATSection new];
    s.header=@"Runtime";
    s.rows=@[
        nav(@"Runtime em tempo real",@"Hub de famílias e imagens carregadas", @"waveform.path.ecg",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRRuntimeGatesVC new] animated:YES];
            }),
        nav(@"WhatsApp Executable",@"Runtime Browser do executável principal", @"app.dashed",
            ^(UIViewController *from){
                WAGRSurfaceSpec *sp=surface(@"exec");
                if(sp) [from.navigationController pushViewController:[[WAGRSurfaceBrowserVC alloc] initWithSpec:sp] animated:YES];
                else alert(from,@"Runtime",@"Surface 'exec' não encontrada.");
            }),
        nav(@"SharedModules",@"Runtime Browser do framework SharedModules", @"shippingbox.fill",
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
        nav(@"Debug",@"Export runtime: UserSession MC · ABProps · stable IDs · Private Experimentation", @"ladybug.fill",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRDebugDiagnosticsVC new] animated:YES];
            }),
        nav(@"Logs",@"Log interno da sessão atual", @"list.bullet.rectangle.portrait.fill",
            ^(UIViewController *from){
                [from.navigationController pushViewController:[WAGRLogViewController new] animated:YES];
            }),
        act(@"Diagnóstico completo",@"RuntimeValueStore · GateStore · LG · Aura · Dogfood · Keychain",
            @"doc.text.magnifyingglass",
            ^(UIViewController *from){
                NSString *msg=[NSString stringWithFormat:
                    @"[LiquidGlass]\n%@\n\n[Aura]\n%@\n\n[Dogfood]\n%@\n\n[GateStore]\n%@\n\n[Settings row]\n%@\n\n[Keychain]\n%@",
                    WAGRLGDiagnosticText()?:@"n/a", WAGRAuraDiagnostic()?:@"n/a",
                    WAGRDogfoodDiagnosticText()?:@"n/a", WAGRGateStoreDiagnostic()?:@"n/a",
                    WAGRSettingsRowsNativeDiagnosticText()?:@"n/a", WAKeychainAccessGroupDiagnostic()?:@"n/a"];
                alert(from,@"Diagnóstico",msg);
            }),
        dtr(@"Reset WATweaks",@"Remove overrides WATweaks e índices runtime", @"trash.fill",
            ^(UIViewController *from){
                UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Reset"
                    message:@"Remove todos os overrides WATweaks gerenciados.\nReinicie o WhatsApp depois."
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
        dtr(@"Reiniciar WhatsApp",@"Fecha o app e descarrega hooks desta sessão", @"power",
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
        initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyAllHooks)];
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
        @"%lu hooks/overrides reaplicados.\nWAAB central hooks: %lu\n\nGateStore semânticos ativos: %lu",
        (unsigned long)n,(unsigned long)waab,(unsigned long)WAGRGateAllOverrides().count];
    alert(self,@"Aplicar",msg);
    [self.tableView reloadData];
}

- (void)rebuildSections {
    _sections=@[secFeatures(),secWAAB(),secRuntime(),secTools()];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tv {
    return (NSInteger)_sections.count;
}
- (NSInteger)tableView:(__unused UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return (NSInteger)_sections[(NSUInteger)sec].rows.count;
}
- (NSString *)tableView:(__unused UITableView *)tv titleForHeaderInSection:(__unused NSInteger)sec { return nil; }
- (NSString *)tableView:(__unused UITableView *)tv titleForFooterInSection:(__unused NSInteger)sec { return nil; }
- (CGFloat)tableView:(__unused UITableView *)tv heightForHeaderInSection:(NSInteger)section { return section == 0 ? 12.0 : 28.0; }
- (CGFloat)tableView:(__unused UITableView *)tv heightForFooterInSection:(__unused NSInteger)section { return 8.0; }
- (CGFloat)tableView:(__unused UITableView *)tv heightForRowAtIndexPath:(__unused NSIndexPath *)ip { return 60.0; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    WATCell *row=_sections[(NSUInteger)ip.section].rows[(NSUInteger)ip.row];
    NSString *rid=[NSString stringWithFormat:@"WATNative-%ld",(long)row.type];
    UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:rid];
    if(!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];

    WAGRMenuApplyCellStyle(cell, ip.row, row.title);
    cell.textLabel.text=row.title;
    cell.textLabel.font=WAGRMenuTitleFont();
    cell.textLabel.numberOfLines=1;
    cell.textLabel.adjustsFontSizeToFitWidth=YES;
    cell.textLabel.minimumScaleFactor=0.72;
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
        case WATCellNav: cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; break;
        case WATCellDestructive: cell.textLabel.textColor=UIColor.systemRedColor; break;
        case WATCellAction: break;
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
