#import "WAGRABPropsFilteredBrowserVC.h"

@interface WAGRABPropsFilteredBrowserVC ()
@property(nonatomic, copy) NSString *wagrInitialQuery;
@property(nonatomic, copy) NSString *wagrPreferredTitle;
@end

@implementation WAGRABPropsFilteredBrowserVC

- (instancetype)initWithUserContext:(id)userContext
                              query:(NSString *)query
                              title:(NSString *)title {
    if (!(self = [super initWithUserContext:userContext])) return nil;
    _wagrInitialQuery = [query copy] ?: @"";
    _wagrPreferredTitle = [title copy] ?: @"AB Props";
    self.title = _wagrPreferredTitle;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *search = self.navigationItem.searchController;
    if (self.wagrInitialQuery.length) {
        search.searchBar.text = self.wagrInitialQuery;
        [self updateSearchResultsForSearchController:search];
    }
    if (self.wagrPreferredTitle.length) self.title = self.wagrPreferredTitle;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.wagrPreferredTitle.length && ![self.title containsString:@"("]) {
        self.title = self.wagrPreferredTitle;
    }
}

@end
