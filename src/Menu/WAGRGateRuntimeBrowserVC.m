// WAGRGateRuntimeBrowserVC.m
#import "WAGRGateRuntimeBrowserVC.h"
#import "../Runtime/WAGRGateStore.h"
#import <objc/runtime.h>

extern BOOL WAGRGateInstallHookForSelector(NSString *className,
                                            NSString *selectorName,
                                            BOOL isClassMethod);

// ── Row model ────────────────────────────────────────────────────────────────
@interface WAGRRuntimeRow : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, assign) BOOL isClassMethod;
@property(nonatomic, assign) BOOL isProperty;
@end
@implementation WAGRRuntimeRow @end

// ── Group model (one section per class) ──────────────────────────────────────
@interface WAGRRuntimeGroup : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, strong) NSMutableArray<WAGRRuntimeRow *> *rows;
@end
@implementation WAGRRuntimeGroup
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _rows = [NSMutableArray array];
    return self;
}
@end

@interface WAGRGateRuntimeBrowserVC ()
@property(nonatomic, strong) WAGRGateProvider *provider;
@property(nonatomic, strong) NSArray<WAGRRuntimeGroup *> *allGroups;
@property(nonatomic, strong) NSArray<WAGRRuntimeGroup *> *visibleGroups;
@property(nonatomic, strong) UISearchController *search;
@end

@implementation WAGRGateRuntimeBrowserVC

- (instancetype)initWithProvider:(WAGRGateProvider *)provider {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _provider = provider;
    self.title = [NSString stringWithFormat:@"%@ · Runtime", provider.title];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"Filtrar por selector ou classe";
    _search.searchBar.barStyle = UIBarStyleBlack;
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    UIBarButtonItem *resetItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.counterclockwise"]
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(resetCategory)];
    self.navigationItem.rightBarButtonItem = resetItem;

    [self scanProvider];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Scan

// Returns YES iff `name` contains any of `fragments` (case-insensitive).
static BOOL WAGRFragmentMatches(NSString *name, NSArray<NSString *> *fragments) {
    if (!fragments.count) return NO;
    for (NSString *frag in fragments) {
        if (frag.length && [name rangeOfString:frag options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// Returns YES iff `selectorName` contains any of `tokens` (case-insensitive).
// An empty token list means "accept everything".
static BOOL WAGRSelectorPassesTokens(NSString *selectorName, NSArray<NSString *> *tokens) {
    if (!tokens.count) return YES;
    for (NSString *t in tokens) {
        if (t.length && [selectorName rangeOfString:t options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// Collect candidate classes for this provider. We deduplicate via NSMutableSet
// of class pointers — concreteClassNames and classNameFragments may overlap.
- (NSArray<Class> *)candidateClasses {
    NSMutableArray<Class> *out = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    void (^add)(Class) = ^(Class c) {
        if (!c) return;
        NSValue *v = [NSValue valueWithPointer:(__bridge const void *)c];
        if ([seen containsObject:v]) return;
        [seen addObject:v];
        [out addObject:c];
    };

    for (NSString *cname in _provider.concreteClassNames) {
        add(NSClassFromString(cname));
    }
    if (_provider.classNameFragments.count) {
        unsigned int n = 0;
        Class *all = objc_copyClassList(&n);
        if (all) {
            for (unsigned int i = 0; i < n; i++) {
                Class c = all[i];
                NSString *cn = NSStringFromClass(c);
                if (WAGRFragmentMatches(cn, _provider.classNameFragments)) add(c);
            }
            free(all);
        }
    }
    return out;
}

// Returns the row list for a single class. Filters: BOOL return, no args
// (numberOfArguments == 2 for instance, 2 for class), and either passes the
// selectorTokens filter or matches one of the provider's featured selectors
// (so users can still toggle a featured flag from the runtime view).
- (WAGRRuntimeGroup *)scanGroupForClass:(Class)cls {
    WAGRRuntimeGroup *group = [WAGRRuntimeGroup new];
    group.className = NSStringFromClass(cls);

    NSMutableSet<NSString *> *featuredNames = [NSMutableSet set];
    for (WAGRGateFeaturedFlag *f in _provider.featured) [featuredNames addObject:f.selectorName];

    void (^scan)(BOOL) = ^(BOOL isMeta) {
        Class target = isMeta ? object_getClass(cls) : cls;
        if (!target) return;
        unsigned int n = 0;
        Method *methods = class_copyMethodList(target, &n);
        if (!methods) return;
        for (unsigned int i = 0; i < n; i++) {
            Method m = methods[i];
            SEL sel = method_getName(m);
            NSString *selName = NSStringFromSelector(sel);
            if (method_getNumberOfArguments(m) != 2) continue;
            char ret[8] = {0};
            method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] != 'B' && ret[0] != 'c') continue;
            if (![featuredNames containsObject:selName]
                && !WAGRSelectorPassesTokens(selName, self.provider.selectorTokens)) {
                continue;
            }
            WAGRRuntimeRow *r = [WAGRRuntimeRow new];
            r.className = group.className;
            r.selectorName = selName;
            r.isClassMethod = isMeta;
            r.isProperty = NO;
            [group.rows addObject:r];
        }
        free(methods);
    };

    if (_provider.scanInstanceMethods) scan(NO);
    if (_provider.scanClassMethods)    scan(YES);

    // Sort selectors alphabetically.
    [group.rows sortUsingComparator:^NSComparisonResult(WAGRRuntimeRow *a, WAGRRuntimeRow *b) {
        return [a.selectorName compare:b.selectorName];
    }];
    return group;
}

- (void)scanProvider {
    NSArray<Class> *classes = [self candidateClasses];
    NSMutableArray<WAGRRuntimeGroup *> *groups = [NSMutableArray array];
    for (Class c in classes) {
        WAGRRuntimeGroup *g = [self scanGroupForClass:c];
        if (g.rows.count) [groups addObject:g];
    }
    [groups sortUsingComparator:^NSComparisonResult(WAGRRuntimeGroup *a, WAGRRuntimeGroup *b) {
        return [a.className compare:b.className];
    }];
    _allGroups = groups;
    _visibleGroups = groups;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (!q.length) { _visibleGroups = _allGroups; [self.tableView reloadData]; return; }
    NSMutableArray<WAGRRuntimeGroup *> *out = [NSMutableArray array];
    for (WAGRRuntimeGroup *g in _allGroups) {
        BOOL classMatches = [g.className rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
        WAGRRuntimeGroup *filtered = [WAGRRuntimeGroup new];
        filtered.className = g.className;
        for (WAGRRuntimeRow *r in g.rows) {
            if (classMatches || [r.selectorName rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered.rows addObject:r];
            }
        }
        if (filtered.rows.count) [out addObject:filtered];
    }
    _visibleGroups = out;
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_visibleGroups.count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return _visibleGroups[(NSUInteger)section].className;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_visibleGroups[(NSUInteger)section].rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    WAGRRuntimeRow *r = _visibleGroups[(NSUInteger)ip.section].rows[(NSUInteger)ip.row];
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"WAGRRuntimeBrowserCell"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"WAGRRuntimeBrowserCell"];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];
    c.textLabel.text = [NSString stringWithFormat:@"%@%@", r.isClassMethod ? @"+ " : @"- ", r.selectorName];
    c.textLabel.textColor = UIColor.labelColor;
    BOOL isSet = WAGRGateIsSet(r.selectorName);
    BOOL value = isSet && WAGRGateGet(r.selectorName);
    NSString *state;
    if (!isSet) state = @"sem override";
    else state = value ? @"override ON" : @"override OFF";
    c.detailTextLabel.text = state;
    c.detailTextLabel.textColor = isSet
        ? (value ? UIColor.systemGreenColor : UIColor.systemRedColor)
        : UIColor.secondaryLabelColor;

    UISwitch *sw = [UISwitch new];
    sw.on = value;
    sw.onTintColor = UIColor.systemGreenColor;
    objc_setAssociatedObject(sw, "wagrRow", r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(rowSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(rowLongPress:)];
    lp.minimumPressDuration = 0.4;
    for (UIGestureRecognizer *g in c.gestureRecognizers) {
        if ([g isKindOfClass:UILongPressGestureRecognizer.class]) [c removeGestureRecognizer:g];
    }
    [c addGestureRecognizer:lp];
    objc_setAssociatedObject(c, "wagrRow", r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return c;
}

- (void)rowSwitchChanged:(UISwitch *)sw {
    WAGRRuntimeRow *r = objc_getAssociatedObject(sw, "wagrRow");
    if (!r) return;
    WAGRGateSet(r.selectorName, sw.isOn);
    if (sw.isOn) {
        (void)WAGRGateInstallHookForSelector(r.className, r.selectorName, r.isClassMethod);
    }
    // Refresh just this row.
    [self.tableView reloadData];
}

- (void)rowLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    WAGRRuntimeRow *r = objc_getAssociatedObject(cell, "wagrRow");
    if (!r) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:r.selectorName
                                                               message:[NSString stringWithFormat:@"%@ %@%@", r.className, r.isClassMethod ? @"+" : @"-", r.selectorName]
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    a.popoverPresentationController.sourceView = cell;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [a addAction:[UIAlertAction actionWithTitle:@"Limpar override" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        WAGRGateClear(r.selectorName);
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Copiar selector" style:UIAlertActionStyleDefault handler:^(__unused id _) {
        UIPasteboard.generalPasteboard.string = r.selectorName;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)resetCategory {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset overrides"
                                                               message:@"Remover todos os overrides cujos selectors são exibidos aqui?"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUInteger n = 0;
        for (WAGRRuntimeGroup *g in self.allGroups) {
            for (WAGRRuntimeRow *r in g.rows) {
                if (WAGRGateIsSet(r.selectorName)) { WAGRGateClear(r.selectorName); n++; }
            }
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
}

@end
