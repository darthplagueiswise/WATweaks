#import "WAGRABPropsFilteredBrowserVC.h"

@interface WAGRABPropsFilteredBrowserVC ()
@property(nonatomic, copy) NSString *wagrInitialQuery;
@property(nonatomic, copy) NSString *wagrDisplayTitle;
@property(nonatomic, assign) BOOL wagrAppliedPreset;
@end

@implementation WAGRABPropsFilteredBrowserVC

- (instancetype)initWithUserContext:(id)userContext
                              query:(NSString *)query
                              title:(NSString *)title {
    self = [super initWithUserContext:userContext];
    if (!self) return nil;
    _wagrInitialQuery = [query copy] ?: @"";
    _wagrDisplayTitle = [title copy] ?: @"ABProps";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.searchController.searchBar.text = self.wagrInitialQuery;
    self.navigationItem.searchController.searchBar.placeholder =
        [NSString stringWithFormat:@"Filtro live: %@", self.wagrInitialQuery.length ? self.wagrInitialQuery : @"todos"];
    self.title = self.wagrDisplayTitle;
    self.wagrAppliedPreset = YES;
    [self updateSearchResultsForSearchController:self.navigationItem.searchController];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.wagrAppliedPreset) return;
    // scanNow updates the count in the title after discovery. Keep the semantic
    // title visible before that async result arrives.
    if (!self.navigationItem.searchController.searchBar.text.length &&
        self.wagrInitialQuery.length) {
        self.navigationItem.searchController.searchBar.text = self.wagrInitialQuery;
    }
}

@end
