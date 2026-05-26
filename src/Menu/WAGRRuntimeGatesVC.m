// WAGRRuntimeGatesVC.m
#import "WAGRRuntimeGatesVC.h"
#import "WAGRGateCategoryVC.h"
#import "../Runtime/WAGRGateRegistry.h"
#import "../Runtime/WAGRGateStore.h"

@interface WAGRRuntimeGatesVC ()
@property(nonatomic, copy) NSArray<WAGRGateProvider *> *providers;
@end

@implementation WAGRRuntimeGatesVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Runtime Gates por Categoria";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _providers = [WAGRGateRegistry allProviders];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

// Counts overrides whose key matches any featured selector OR any class-named
// selector loaded via the registry's concrete classes. We deliberately keep
// the count cheap — it iterates the small NSUserDefaults gate-keys set and
// does NSString prefix checks; no class scanning happens here.
static NSUInteger WAGRCountOverridesForProvider(WAGRGateProvider *p) {
    NSArray<NSString *> *all = WAGRGateAllOverrides();
    if (!all.count) return 0;
    NSMutableSet<NSString *> *featuredNames = [NSMutableSet setWithCapacity:p.featured.count];
    for (WAGRGateFeaturedFlag *f in p.featured) [featuredNames addObject:f.selectorName];
    NSUInteger n = 0;
    for (NSString *key in all) if ([featuredNames containsObject:key]) n++;
    return n;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_providers.count; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    return @"Cada categoria mostra flags principais com toggle direto. "
           @"Dentro dela, o botão Runtime Avançado abre os getters descobertos "
           @"por classe/selector para ajuste fino.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    WAGRGateProvider *p = _providers[(NSUInteger)ip.row];
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"WAGRRuntimeGatesCell"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRRuntimeGatesCell"];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = p.title;
    c.textLabel.textColor = UIColor.labelColor;
    NSUInteger overrides = WAGRCountOverridesForProvider(p);
    NSString *subtitle = overrides
        ? [NSString stringWithFormat:@"%@ · %lu overrides", p.subtitle ?: @"", (unsigned long)overrides]
        : (p.subtitle ?: @"");
    c.detailTextLabel.text = subtitle;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    UIImage *img = [UIImage systemImageNamed:p.icon ?: @"circle"];
    c.imageView.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    c.imageView.tintColor = overrides ? UIColor.systemGreenColor : UIColor.labelColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    WAGRGateProvider *p = _providers[(NSUInteger)ip.row];
    WAGRGateCategoryVC *vc = [[WAGRGateCategoryVC alloc] initWithProvider:p];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
