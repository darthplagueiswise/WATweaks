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
    self.title = @"Runtime em Tempo Real";
    _allSurfaces = @[];
    _visibleSurfaces = @[];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Buscar família carregada agora";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchController = search;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self
        action:@selector(reloadRuntime)];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(reloadRuntime) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self reloadRuntime];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)reloadRuntime {
    if (self.scanning) return;
    self.scanning = YES;
    self.title = @"Lendo runtime carregado…";
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
                for (NSString *token in tokens) {
                    if (![haystack containsString:token]) return NO;
                }
                return YES;
            }]];
    }
    self.title = [NSString stringWithFormat:@"Runtime (%lu famílias)",
        (unsigned long)self.visibleSurfaces.count];
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

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.visibleSurfaces.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return @"Famílias descobertas agora";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"As categorias não vêm mais de registry, JSON ou lista de palavras do tweak. "
            "Elas são reconstruídas dos selectors zero-arg, classes e imagens Mach-O que estão carregados neste processo. "
            "Puxe para atualizar depois que outro framework ou módulo for carregado.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WAGRSurfaceSpec *surface = self.visibleSurfaces[(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRLiveFamilyCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"WAGRLiveFamilyCell"];
    }
    WAGRMenuApplyCellStyle(cell, indexPath.row, surface.surfaceID ?: surface.title);
    cell.textLabel.text = surface.title;
    NSUInteger overrides = WAGRLiveOverrideCountForFamily(surface.runtimeFamilyKey);
    cell.detailTextLabel.text = overrides
        ? [NSString stringWithFormat:@"%@ · %lu overrides tipados", surface.subtitle ?: @"",
                                      (unsigned long)overrides]
        : (surface.subtitle ?: @"");
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = overrides ? UIColor.systemGreenColor : WAGRMenuSecondaryTextColor();
    cell.imageView.image = WAGRMenuSymbol(surface.icon ?: @"line.3.horizontal.decrease.circle", nil);
    cell.imageView.tintColor = overrides ? UIColor.systemGreenColor
                                         : WAGRMenuAccentForKey(surface.title, indexPath.row);
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
