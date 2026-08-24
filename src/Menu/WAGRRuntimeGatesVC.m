#import "WAGRRuntimeGatesVC.h"
#import "WAGRSurfaceBrowserVC.h"
#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRRuntimeValueStore.h"
#import "WAGRMenuTheme.h"

@interface WAGRRuntimeGatesVC ()
@property(nonatomic, copy) NSArray<WAGRSurfaceSpec *> *allSurfaces;
@property(nonatomic, copy) NSArray<WAGRSurfaceSpec *> *visibleSurfaces;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, assign) BOOL scanning;
@end

@implementation WAGRRuntimeGatesVC

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Runtime";
    _allSurfaces = @[];
    _visibleSurfaces = @[];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.estimatedRowHeight = 54.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Buscar família";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchController = search;
    WAGRMenuApplySearchGlass(search.searchBar);

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self
        action:@selector(reloadRuntime)];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(reloadRuntime) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self reloadRuntime];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    WAGRMenuApplySearchGlass(self.searchController.searchBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)reloadRuntime {
    if (self.scanning) return;
    self.scanning = YES;
    self.title = @"Lendo runtime…";
    self.navigationItem.rightBarButtonItem.enabled = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WAGRSurfaceSpec *> *surfaces = [WAGRScanner runtimeFamilySurfaces];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.navigationItem.rightBarButtonItem.enabled = YES;
            [self.refreshControl endRefreshing];
            self.allSurfaces = surfaces ?: @[];
            [self applyFilter:self.searchController.searchBar.text ?: @""];
        });
    });
}

static NSArray<NSString *> *WAGRLiveSearchTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [query.lowercaseString componentsSeparatedByCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens;
}

- (void)applyFilter:(NSString *)query {
    NSArray<NSString *> *tokens = WAGRLiveSearchTokens(query ?: @"");
    if (!tokens.count) {
        self.visibleSurfaces = self.allSurfaces;
    } else {
        self.visibleSurfaces = [self.allSurfaces filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(WAGRSurfaceSpec *surface,
                                                   __unused NSDictionary *bindings) {
                NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@",
                    surface.title ?: @"", surface.subtitle ?: @"", surface.runtimeFamilyKey ?: @""].lowercaseString;
                for (NSString *token in tokens) if (![haystack containsString:token]) return NO;
                return YES;
            }]];
    }
    self.title = [NSString stringWithFormat:@"Runtime (%lu)", (unsigned long)self.visibleSurfaces.count];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text ?: @""];
}

static NSUInteger WAGRLiveOverrideCountForFamily(NSString *family) {
    if (!family.length) return 0;
    NSUInteger count = 0;
    for (NSDictionary *spec in WAGRRuntimeValueAllOverrideSpecs()) {
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        if ([[WAGRLiveRuntimeFamilyForSelector(selector, className) lowercaseString]
             isEqualToString:family.lowercaseString]) count++;
    }
    return count;
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.visibleSurfaces.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section { return nil; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section { return nil; }
- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(__unused NSInteger)section { return CGFLOAT_MIN; }
- (CGFloat)tableView:(__unused UITableView *)tableView heightForFooterInSection:(__unused NSInteger)section { return CGFLOAT_MIN; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WAGRSurfaceSpec *surface = self.visibleSurfaces[(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRCompactFamilyCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRCompactFamilyCell"];
    WAGRMenuApplyCellStyle(cell, indexPath.row, surface.surfaceID ?: surface.title);
    cell.textLabel.font = WAGRMenuRuntimeTitleFont();
    cell.detailTextLabel.font = WAGRMenuRuntimeDetailFont();
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.text = surface.title;

    NSUInteger overrides = WAGRLiveOverrideCountForFamily(surface.runtimeFamilyKey);
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%lu getters · %lu classes",
        (unsigned long)surface.runtimeEntryCount, (unsigned long)surface.runtimeClassCount];
    if (overrides) [detail appendFormat:@" · %lu overrides", (unsigned long)overrides];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = overrides ? UIColor.systemCyanColor : WAGRMenuSecondaryTextColor();
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WAGRSurfaceSpec *surface = self.visibleSurfaces[(NSUInteger)indexPath.row];
    WAGRSurfaceBrowserVC *browser = [[WAGRSurfaceBrowserVC alloc] initWithSpec:surface];
    [self.navigationController pushViewController:browser animated:YES];
}

@end
