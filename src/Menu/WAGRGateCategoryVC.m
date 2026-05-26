// WAGRGateCategoryVC.m
#import "WAGRGateCategoryVC.h"
#import "WAGRGateRuntimeBrowserVC.h"
#import "../Runtime/WAGRGateStore.h"
#import "WAGRMenuTheme.h"

// Provided by WAGRGateHooks.xm. Installs the gate trampoline on one
// concrete (class, selector, isClassMethod) tuple. Idempotent.
extern BOOL WAGRGateInstallHookForSelector(NSString *className,
                                            NSString *selectorName,
                                            BOOL isClassMethod);
extern void WAGRGateHooksEnsureInstalled(void);

typedef NS_ENUM(NSInteger, WAGRCategorySection) {
    WAGRCategorySectionFeatured = 0,
    WAGRCategorySectionActions,
    WAGRCategorySectionCount
};

typedef NS_ENUM(NSInteger, WAGRCategoryAction) {
    WAGRCategoryActionRuntimeBrowser = 0,
    WAGRCategoryActionResetCategory,
    WAGRCategoryActionCount
};

@interface WAGRGateCategoryVC ()
@property(nonatomic, strong) WAGRGateProvider *provider;
@end

@implementation WAGRGateCategoryVC

- (instancetype)initWithProvider:(WAGRGateProvider *)provider {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _provider = provider;
    self.title = provider.title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    if (![self shouldHideApplyButton]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Aplicar" style:UIBarButtonItemStyleDone target:self action:@selector(applyFeaturedOverrides)];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}


- (BOOL)shouldHideApplyButton {
    NSString *pid = self.provider.providerID.lowercaseString ?: @"";
    return [pid containsString:@"negative"] || [pid containsString:@"kill"];
}

static BOOL WAGRCategoryShouldSkipApply(NSString *selectorName) {
    return WAGRMenuIsNegativeGateName(selectorName);
}

// ── Hook install helper used when the user flips a featured switch ON ────────
// We don't know which of the provider's concrete classes actually owns the
// selector for a given build; we try them in order and stop at the first
// success. Class methods are tried after instance methods because most
// featured flags are instance-level. Missing classes are silently skipped.
static BOOL WAGRTryInstallFeaturedHook(WAGRGateProvider *provider, NSString *selector) {
    for (NSString *cname in provider.concreteClassNames) {
        if (WAGRGateInstallHookForSelector(cname, selector, NO)) return YES;
    }
    for (NSString *cname in provider.concreteClassNames) {
        if (WAGRGateInstallHookForSelector(cname, selector, YES)) return YES;
    }
    return NO;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return WAGRCategorySectionCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch ((WAGRCategorySection)section) {
        case WAGRCategorySectionFeatured: return (NSInteger)_provider.featured.count;
        case WAGRCategorySectionActions:  return WAGRCategoryActionCount;
        case WAGRCategorySectionCount:    return 0;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch ((WAGRCategorySection)section) {
        case WAGRCategorySectionFeatured: return @"Flags principais";
        case WAGRCategorySectionActions:  return @"Ações";
        case WAGRCategorySectionCount:    return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WAGRCategorySectionFeatured) {
        return @"Toque no switch para preparar ON/OFF e use Aplicar para instalar os hooks da categoria. "
               @"Long-press limpa o override. Negative/Kill Switch não são aplicados em massa por segurança.";
    }
    return nil;
}

- (UITableViewCell *)cellForFeatured:(WAGRGateFeaturedFlag *)flag {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(c, 0, flag.selectorName);
    c.textLabel.text = flag.title;
    NSMutableString *detail = [NSMutableString string];
    [detail appendString:flag.selectorName ?: @""];
    if (flag.detail.length) {
        [detail appendString:@"\n"];
        [detail appendString:flag.detail];
    }
    if (flag.inverted) {
        [detail appendString:@"\n(invertido: ON na UI = retorna NO)"];
    }
    c.detailTextLabel.text = detail;
    c.detailTextLabel.textColor = WAGRCategoryShouldSkipApply(flag.selectorName) ? UIColor.systemRedColor : WAGRMenuSecondaryTextColor();
    c.detailTextLabel.numberOfLines = 0;

    UISwitch *sw = [UISwitch new];
    BOOL isSet = WAGRGateIsSet(WAGRGateCanonicalKey(flag.selectorName));
    sw.on = isSet && WAGRGateGet(WAGRGateCanonicalKey(flag.selectorName));
    sw.onTintColor = isSet ? UIColor.systemGreenColor : UIColor.systemBlueColor;
    [sw addTarget:self action:@selector(featuredSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    sw.accessibilityIdentifier = flag.selectorName;
    c.accessoryView = sw;

    // Show a small badge when an override exists, so the user can distinguish
    // "explicitly OFF" from "no override yet".
    if (isSet) {
        UILabel *badge = [UILabel new];
        badge.text = WAGRGateGet(WAGRGateCanonicalKey(flag.selectorName)) ? @" override ON " : @" override OFF ";
        badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        badge.textColor = UIColor.whiteColor;
        badge.backgroundColor = WAGRGateGet(WAGRGateCanonicalKey(flag.selectorName))
            ? [UIColor.systemGreenColor colorWithAlphaComponent:.85]
            : [UIColor.systemRedColor colorWithAlphaComponent:.85];
        badge.layer.cornerRadius = 4;
        badge.layer.masksToBounds = YES;
        [badge sizeToFit];
        c.detailTextLabel.attributedText = nil;
    }

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(featuredLongPress:)];
    lp.minimumPressDuration = 0.4;
    [c addGestureRecognizer:lp];
    return c;
}

- (UITableViewCell *)cellForAction:(WAGRCategoryAction)action {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WAGRMenuApplyCellStyle(c, action, self.provider.providerID);
    switch (action) {
        case WAGRCategoryActionRuntimeBrowser:
            c.textLabel.text = @"Runtime Avançado";
            c.detailTextLabel.text = @"Listar TODOS os selectors BOOL desta categoria descobertos em runtime.";
            c.imageView.image = WAGRMenuSymbol(@"binoculars.fill", nil);
            c.imageView.tintColor = UIColor.systemBlueColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case WAGRCategoryActionResetCategory:
            c.textLabel.text = @"Reset overrides desta categoria";
            c.detailTextLabel.text = @"Remove apenas os overrides cujos nomes correspondem aos flags principais.";
            c.imageView.image = WAGRMenuSymbol(@"arrow.counterclockwise.circle.fill", nil);
            c.imageView.tintColor = UIColor.systemRedColor;
            break;
        case WAGRCategoryActionCount: break;
    }
    c.textLabel.textColor = WAGRMenuTextColor();
    c.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    c.detailTextLabel.numberOfLines = 0;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch ((WAGRCategorySection)ip.section) {
        case WAGRCategorySectionFeatured:
            return [self cellForFeatured:_provider.featured[(NSUInteger)ip.row]];
        case WAGRCategorySectionActions:
            return [self cellForAction:(WAGRCategoryAction)ip.row];
        case WAGRCategorySectionCount: break;
    }
    return [[UITableViewCell alloc] init];
}

- (void)applyFeaturedOverrides {
    NSUInteger installed = 0;
    NSUInteger skipped = 0;
    NSUInteger setCount = 0;

    WAGRGateHooksEnsureInstalled();
    for (WAGRGateFeaturedFlag *f in self.provider.featured) {
        NSString *sel = WAGRGateCanonicalKey(f.selectorName);
        if (!WAGRGateIsSet(sel)) continue;
        setCount++;
        if (WAGRCategoryShouldSkipApply(f.selectorName)) { skipped++; continue; }
        if (WAGRTryInstallFeaturedHook(self.provider, f.selectorName)) installed++;
    }

    NSString *msg = [NSString stringWithFormat:@"Overrides nesta categoria: %lu\nHooks diretos instalados: %lu\nIgnorados por segurança (negative/kill/disable/block): %lu\nWAAB boolForKey: fica coberto pelo hook central.",
                     (unsigned long)setCount, (unsigned long)installed, (unsigned long)skipped];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Aplicar categoria"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    [self.tableView reloadData];
}

#pragma mark - Featured interaction

- (void)featuredSwitchChanged:(UISwitch *)sw {
    NSString *selectorName = sw.accessibilityIdentifier;
    if (!selectorName.length) return;
    WAGRGateSet(selectorName, sw.isOn);
    if (!WAGRCategoryShouldSkipApply(selectorName)) {
        // Install for both ON and OFF overrides; explicit OFF needs a hook too.
        (void)WAGRTryInstallFeaturedHook(_provider, selectorName);
        WAGRGateHooksEnsureInstalled();
    }
    // Rebuild the row so the badge updates.
    NSUInteger row = NSNotFound;
    for (NSUInteger i = 0; i < _provider.featured.count; i++) {
        if ([_provider.featured[i].selectorName isEqualToString:selectorName]) { row = i; break; }
    }
    if (row != NSNotFound) {
        [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:(NSInteger)row inSection:WAGRCategorySectionFeatured] ]
                             withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)featuredLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    UISwitch *sw = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : nil;
    NSString *selectorName = sw.accessibilityIdentifier;
    if (!selectorName.length) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:selectorName
                                                               message:@"Limpar override (volta ao valor original)?"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.sourceView = cell;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [a addAction:[UIAlertAction actionWithTitle:@"Limpar" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        WAGRGateClear(selectorName);
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Action selection

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != WAGRCategorySectionActions) return;

    switch ((WAGRCategoryAction)ip.row) {
        case WAGRCategoryActionRuntimeBrowser: {
            WAGRGateRuntimeBrowserVC *vc = [[WAGRGateRuntimeBrowserVC alloc] initWithProvider:_provider];
            [self.navigationController pushViewController:vc animated:YES];
            return;
        }
        case WAGRCategoryActionResetCategory: {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset categoria"
                                                                       message:@"Remover overrides apenas dos flags principais desta categoria?"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
                NSUInteger n = 0;
                for (WAGRGateFeaturedFlag *f in self.provider.featured) {
                    if (WAGRGateIsSet(WAGRGateCanonicalKey(f.selectorName))) { WAGRGateClear(WAGRGateCanonicalKey(f.selectorName)); n++; }
                }
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Reset"
                                                                              message:[NSString stringWithFormat:@"%lu overrides removidos.", (unsigned long)n]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:done animated:YES completion:nil];
                [self.tableView reloadData];
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        case WAGRCategoryActionCount: return;
    }
}

@end
