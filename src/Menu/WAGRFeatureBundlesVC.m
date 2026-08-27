#import "WAGRFeatureBundlesVC.h"
#import "WAGRABPropsFilteredBrowserVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"

@interface WAGRLiveFeatureFamily : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSString *icon;
@property(nonatomic, assign) NSUInteger count;
@end
@implementation WAGRLiveFeatureFamily @end

extern id WAGRCurrentUserContext(void);

static NSArray<WAGRLiveFeatureFamily *> *WAGRFeatureSemanticFamilies(void) {
    // These are semantic views, never a list of product selectors or stable IDs.
    // A family is shown only when the current runtime actually contains matches.
    NSArray<NSArray<NSString *> *> *definitions = @[
        @[@"Todos os ABProps atuais", @"", @"switch.2"],
        @[@"Internal", @"internal", @"hammer.fill"],
        @[@"Employee", @"employee", @"person.crop.circle.badge.checkmark"],
        @[@"Dogfood", @"dogfood", @"pawprint.fill"],
        @[@"Fishfood", @"fishfood", @"fish.fill"],
        @[@"Liquid Glass", @"liquid_glass", @"circle.hexagongrid.fill"],
        @[@"Aura / WA Plus", @"aura", @"sparkles"],
        @[@"Private Experimentation", @"private", @"flask.fill"],
        @[@"Bug Reporting", @"bug_report", @"ladybug.fill"],
        @[@"Rage Shake", @"rage_shake", @"iphone.radiowaves.left.and.right"],
    ];
    NSMutableArray *families = [NSMutableArray arrayWithCapacity:definitions.count];
    for (NSArray<NSString *> *row in definitions) {
        WAGRLiveFeatureFamily *family = [WAGRLiveFeatureFamily new];
        family.title = row[0];
        family.query = row[1];
        family.icon = row[2];
        [families addObject:family];
    }
    return families;
}

static NSString *WAGRFeatureHaystack(WAGRABPropEntry *entry) {
    return [NSString stringWithFormat:@"%@ %@ %@ %@ %@",
        entry.selectorName ?: @"",
        entry.className ?: @"",
        entry.categoryName ?: @"",
        entry.sourceImage ?: @"",
        entry.typeName ?: @""].lowercaseString;
}

@interface WAGRFeatureBundlesVC ()
@property(nonatomic, copy) NSArray<WAGRLiveFeatureFamily *> *families;
@property(nonatomic, assign) NSUInteger liveEntryCount;
@property(nonatomic, assign) NSUInteger stableIDCount;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WAGRFeatureBundlesVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.title = @"Features / Experimentos";
    _families = @[];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 72.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UIActivityIndicatorViewStyle style = UIActivityIndicatorViewStyleMedium;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:style];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.spinner];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(scanLiveFamilies)
      forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.families.count && !self.scanning) [self scanLiveFamilies];
}

- (void)scanLiveFamilies {
    if (self.scanning) return;
    self.scanning = YES;
    [self.spinner startAnimating];
    self.title = @"Descobrindo features…";
    id context = WAGRCurrentUserContext();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *objects = WAGRABPropsResolveRuntimeObjects(context);
        NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
        NSArray<WAGRLiveFeatureFamily *> *definitions = WAGRFeatureSemanticFamilies();

        NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
        NSUInteger stableIDs = 0;
        for (WAGRABPropEntry *entry in entries) {
            NSString *haystack = WAGRFeatureHaystack(entry);
            NSString *stableID = WAGRABPropsStableIDForTarget(entry.className,
                                                               entry.selectorName,
                                                               entry.classMethod);
            if (stableID.length) stableIDs++;
            for (WAGRLiveFeatureFamily *family in definitions) {
                if (!family.query.length) continue;
                if ([haystack containsString:family.query.lowercaseString]) {
                    counts[family.query] = @([counts[family.query] unsignedIntegerValue] + 1);
                }
            }
        }

        NSMutableArray<WAGRLiveFeatureFamily *> *visible = [NSMutableArray array];
        for (WAGRLiveFeatureFamily *family in definitions) {
            family.count = family.query.length
                ? [counts[family.query] unsignedIntegerValue]
                : entries.count;
            if (!family.query.length || family.count > 0) [visible addObject:family];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            [self.spinner stopAnimating];
            [self.refreshControl endRefreshing];
            self.liveEntryCount = entries.count;
            self.stableIDCount = stableIDs;
            self.families = visible;
            self.title = @"Features / Experimentos";
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.families.count;
    return 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Catálogo vivo" : @"Modelo";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    if (self.scanning) return @"Lendo apenas getters carregados nesta versão do WhatsApp.";
    return [NSString stringWithFormat:
        @"%lu getters tipados descobertos agora · %lu stable IDs decodificados do IMP. Categorias com zero resultados são ocultadas. Nenhum selector ou AB ID de produto é mantido nesta tela.",
        (unsigned long)self.liveEntryCount, (unsigned long)self.stableIDCount];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WAGRLiveFeatureFamilyCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    if (indexPath.section == 1) {
        WAGRMenuApplyCellStyle(cell, indexPath.row, @"runtime-model");
        cell.textLabel.text = @"Sem presets de gates";
        cell.detailTextLabel.text = @"Cada submenu é somente um filtro sobre ABProps/Private Experimentation realmente presentes no runtime atual.";
        cell.imageView.image = WAGRMenuSymbol(@"info.circle.fill", UIColor.whiteColor);
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = WAGRMenuTitleFont();
        cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
        cell.detailTextLabel.numberOfLines = 0;
        return cell;
    }

    WAGRLiveFeatureFamily *family = self.families[(NSUInteger)indexPath.row];
    WAGRMenuApplyCellStyle(cell, indexPath.row, family.title);
    cell.textLabel.text = family.title;
    cell.detailTextLabel.text = [NSString stringWithFormat:
        @"%lu getters atuais · filtro runtime '%@'",
        (unsigned long)family.count, family.query.length ? family.query : @"todos"];
    cell.imageView.image = WAGRMenuSymbol(family.icon, UIColor.whiteColor);
    cell.textLabel.font = WAGRMenuTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.detailTextLabel.textColor = WAGRMenuSecondaryTextColor();
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)self.families.count) return;
    WAGRLiveFeatureFamily *family = self.families[(NSUInteger)indexPath.row];
    WAGRABPropsFilteredBrowserVC *browser = [[WAGRABPropsFilteredBrowserVC alloc]
        initWithUserContext:WAGRCurrentUserContext()
        query:family.query
        title:family.title];
    [self.navigationController pushViewController:browser animated:YES];
}

@end
