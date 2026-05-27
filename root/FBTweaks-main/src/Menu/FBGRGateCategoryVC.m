#import "FBGRGateCategoryVC.h"
#import "FBGRMenuTheme.h"
#import "FBGRGateRuntimeBrowserVC.h"
#import "../Runtime/FBGRGateStore.h"
#import "../Runtime/FBGRMCCatalog.h"
#import "../FBGramPrefix.h"

typedef NS_ENUM(NSInteger, FBGRCatSection) {
    FBGRCatSectionFeatured = 0,
    FBGRCatSectionActions  = 1,
    FBGRCatSectionCount    = 2,
};

@interface FBGRGateCategoryVC ()
@property(nonatomic, strong) FBGRGateProvider *provider;
@end

@implementation FBGRGateCategoryVC

- (instancetype)initWithProvider:(FBGRGateProvider *)p {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _provider = p; self.title = p.title; return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    FBGRApplyTable(self.tableView, self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Limpar tudo" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearAll)];
    [[FBGRMCCatalog shared] loadIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self.tableView reloadData];
}

- (void)clearAll {
    for (FBGRFeaturedFlag *f in self.provider.featured)
        if (f.slotId > 0) FBGRGateClear(f.slotId);
    [self.tableView reloadData];
}

// ── TableView ─────────────────────────────────────────────────────────────────
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return FBGRCatSectionCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == FBGRCatSectionFeatured) return (NSInteger)self.provider.featured.count;
    return 2; // "Runtime Avançado" + "Resetar categoria"
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == FBGRCatSectionFeatured ? @"Flags principais" : @"Ações";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s != FBGRCatSectionFeatured) return nil;
    NSUInteger set = 0;
    for (FBGRFeaturedFlag *f in self.provider.featured)
        if (f.slotId > 0 && FBGRGateIsSet(f.slotId)) set++;
    return [NSString stringWithFormat:@"%lu/%lu flags com override",
            (unsigned long)set, (unsigned long)self.provider.featured.count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == FBGRCatSectionFeatured) {
        FBGRFeaturedFlag *flag = self.provider.featured[(NSUInteger)ip.row];

        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"feat"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"feat"];
        FBGRApplyCell(c, ip.row, self.provider.accentColor);
        c.selectionStyle = UITableViewCellSelectionStyleNone;

        // slotId 0 → special LiquidGlass C gate (fishhook, uses master pref)
        BOOL isOn;
        if (flag.slotId == 0) {
            isOn = FBGRPref(kFBGRLiquidGlassMaster);
        } else {
            isOn = FBGRGateIsSet(flag.slotId) && FBGRGateGet(flag.slotId);
        }

        c.textLabel.text = flag.title;
        // Enrich detail from catalog
        FBGRMCParam *param = flag.slotId > 0 ? [[FBGRMCCatalog shared] paramForSlotId:flag.slotId] : nil;
        NSString *detail = flag.detail ?: @"";
        if (param && !FBGRGateIsSet(flag.slotId)) {
            detail = [detail stringByAppendingFormat:@" (default=%@)", param.defaultBool ? @"YES" : @"NO"];
        } else if (FBGRGateIsSet(flag.slotId)) {
            detail = [detail stringByAppendingFormat:@" → FORÇADO %@", FBGRGateGet(flag.slotId) ? @"YES" : @"NO"];
        }
        c.detailTextLabel.text = detail;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = isOn;
        sw.tag = (NSInteger)ip.row;
        sw.onTintColor = FBGRAccentForProvider(self.provider.accentColor);
        [sw removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
        [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    // Actions
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"act"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"act"];
    FBGRApplyCell(c, ip.section * 10 + ip.row, nil);
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    c.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;

    if (ip.row == 0) {
        c.textLabel.text  = @"Runtime Avançado";
        c.imageView.image = FBGRSymbol(@"cpu", FBGRAccentForProvider(self.provider.accentColor));
    } else {
        c.textLabel.text  = @"Resetar todos os overrides desta categoria";
        c.textLabel.textColor = UIColor.systemRedColor;
        c.imageView.image = FBGRSymbol(@"trash", UIColor.systemRedColor);
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != FBGRCatSectionActions) return;
    if (ip.row == 0) {
        FBGRGateRuntimeBrowserVC *vc = [[FBGRGateRuntimeBrowserVC alloc] initWithProvider:self.provider];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        [self clearAll];
    }
}

- (void)switchToggled:(UISwitch *)sw {
    FBGRFeaturedFlag *flag = self.provider.featured[(NSUInteger)sw.tag];
    if (flag.slotId == 0) {
        // LiquidGlass C gate
        [FBGRPrefs() setBool:sw.isOn forKey:kFBGRLiquidGlassMaster];
        [FBGRPrefs() synchronize];
    } else {
        if (sw.isOn) FBGRGateSet(flag.slotId, YES);
        else FBGRGateClear(flag.slotId);
    }
    NSIndexPath *ip = [NSIndexPath indexPathForRow:sw.tag inSection:FBGRCatSectionFeatured];
    [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:FBGRCatSectionFeatured]
                  withRowAnimation:UITableViewRowAnimationNone];
}

@end
