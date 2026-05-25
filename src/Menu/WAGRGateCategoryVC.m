// WAGRGateCategoryVC.m
#import "WAGRGateCategoryVC.h"
#import "WAGRGateRuntimeBrowserVC.h"
#import "../Runtime/WAGRGateStore.h"

// Provided by WAGRGateHooks.xm. Installs the gate trampoline on one
// concrete (class, selector, isClassMethod) tuple. Idempotent.
extern BOOL WAGRGateInstallHookForSelector(NSString *className,
                                            NSString *selectorName,
                                            BOOL isClassMethod);

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
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
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
        return @"Toque no switch para forçar ON/OFF. Long-press na linha para limpar o override (volta ao comportamento original). "
               @"Para flags fora desta lista, use \"Runtime Avançado\".";
    }
    return nil;
}

- (UITableViewCell *)cellForFeatured:(WAGRGateFeaturedFlag *)flag {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = flag.title;
    c.textLabel.textColor = UIColor.labelColor;
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
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;

    UISwitch *sw = [UISwitch new];
    BOOL isSet = WAGRGateIsSet(WAGRGateCanonicalKey(flag.selectorName));
    sw.on = isSet && WAGRGateGet(WAGRGateCanonicalKey(flag.selectorName));
    sw.onTintColor = isSet ? UIColor.systemGreenColor : UIColor.systemBlueColor;
    [sw addTarget:self action:@selector(featuredSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    sw.accessibilityIdentifier = WAGRGateCanonicalKey(flag.selectorName);
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
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    switch (action) {
        case WAGRCategoryActionRuntimeBrowser:
            c.textLabel.text = @"Runtime Avançado";
            c.detailTextLabel.text = @"Listar TODOS os selectors BOOL desta categoria descobertos em runtime.";
            c.imageView.image = [[UIImage systemImageNamed:@"binoculars"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            c.imageView.tintColor = UIColor.systemBlueColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case WAGRCategoryActionResetCategory:
            c.textLabel.text = @"Reset overrides desta categoria";
            c.detailTextLabel.text = @"Remove apenas os overrides cujos nomes correspondem aos flags principais.";
            c.imageView.image = [[UIImage systemImageNamed:@"arrow.counterclockwise"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            c.imageView.tintColor = UIColor.systemRedColor;
            break;
        case WAGRCategoryActionCount: break;
    }
    c.textLabel.textColor = UIColor.labelColor;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
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

#pragma mark - Featured interaction

- (void)featuredSwitchChanged:(UISwitch *)sw {
    NSString *selectorName = sw.accessibilityIdentifier;
    if (!selectorName.length) return;
    WAGRGateSet(selectorName, sw.isOn);
    if (sw.isOn) {
        // Only install a runtime hook if the universal boolForKey: hook
        // is not enough — i.e. this selector is a direct BOOL method.
        // Try each concrete class; failure here is fine (the
        // boolForKey: hook on WAABProperties will still apply for
        // WAAB-shaped flag names).
        (void)WAGRTryInstallFeaturedHook(_provider, selectorName);
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
