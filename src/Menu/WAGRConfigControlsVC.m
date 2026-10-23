#import "WAGRConfigControlsVC.h"
#import "../Runtime/WAGRABPropsRuntime.h"
#import "WAGRMenuTheme.h"

@interface WAGRConfigControlsVC ()
@property(nonatomic) WAGRConfigControlGroup controlGroup;
@property(nonatomic) BOOL nativeWriter;
@property(nonatomic, strong) UISegmentedControl *backendControl;
@property(nonatomic, strong) UILabel *controlStatus;
@end

@implementation WAGRConfigControlsVC

- (instancetype)initWithUserContext:(id)context group:(WAGRConfigControlGroup)group {
    self = [super initWithUserContext:context];
    if (!self) return nil;
    _controlGroup = group;
    _nativeWriter = [NSUserDefaults.standardUserDefaults boolForKey:@"watweak.config_controls.native_writer"];
    self.title = [self groupTitle];
    return self;
}

- (NSString *)groupTitle {
    return [NSString stringWithUTF8String:WAGRConfigControlGroupTitle(self.controlGroup)];
}

- (BOOL)buildMatches {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"";
    return WAGRConfigControlCatalogBuildMatches(version.UTF8String, build.UTF8String);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 176)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UISegmentedControl *backend = [[UISegmentedControl alloc] initWithItems:@[@"Leitura local", @"MC nativo"]];
    backend.translatesAutoresizingMaskIntoConstraints = NO;
    backend.selectedSegmentIndex = self.nativeWriter ? 1 : 0;
    backend.enabled = [self buildMatches];
    [backend addTarget:self action:@selector(backendChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:backend];
    self.backendControl = backend;
    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.numberOfLines = 0;
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    status.textColor = WAGRMenuSecondaryTextColor();
    self.controlStatus = status;
    [header addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [backend.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [backend.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [backend.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [status.topAnchor constraintEqualToAnchor:backend.bottomAnchor constant:10],
        [status.leadingAnchor constraintEqualToAnchor:backend.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:backend.trailingAnchor]
    ]];
    self.tableView.tableHeaderView = header;
    [self updateControlStatus:0];
}

- (void)updateControlStatus:(NSUInteger)count {
    if (![self buildMatches]) {
        self.controlStatus.text = @"Controles não disponíveis: o catálogo foi validado na IPA 26.40.10 (1086609742). Use o browser runtime para inspecionar esta build.";
        return;
    }
    self.controlStatus.text = [NSString stringWithFormat:
        @"%lu controles disponíveis. Nativo remove o override da camada selecionada; OFF grava false. Leitura local substitui o getter; MC nativo exige confirmação. Alterar uma leitura não dispara fetch. Gates já armazenados em cache podem exigir reinício.", (unsigned long)count];
}

- (void)backendChanged:(UISegmentedControl *)sender {
    if ([self wagrHasActiveOperation]) {
        sender.selectedSegmentIndex = self.nativeWriter ? 1 : 0;
        return;
    }
    self.nativeWriter = sender.selectedSegmentIndex == 1;
    [NSUserDefaults.standardUserDefaults setBool:self.nativeWriter forKey:@"watweak.config_controls.native_writer"];
    [self scanNow];
}

- (void)scanNow {
    if (![self buildMatches]) {
        [self.refreshControl endRefreshing];
        [self updateControlStatus:0];
        return;
    }
    [super scanNow];
}

- (BOOL)wagrUsesThreeStateControls { return YES; }
- (BOOL)wagrUsesNativeABPropertiesWriter { return self.nativeWriter; }
- (BOOL)wagrAllowsRuntimeABPropertiesFallback { return NO; }
- (BOOL)wagrShowsABTFetchControl { return NO; }
- (BOOL)wagrIncludesRuntimeEntry:(WAGRABPropEntry *)entry {
    if (![self buildMatches] || entry.classMethod || ![entry.className isEqualToString:@"WAABProperties"]) return NO;
    const WAGRConfigControlDefinition *definition = WAGRConfigControlFind(entry.selectorName.UTF8String);
    return definition && definition->group == self.controlGroup &&
        [entry.typeCode isEqualToString:[NSString stringWithUTF8String:definition->type]];
}
- (NSString *)wagrDisplayTitleForEntry:(WAGRABPropEntry *)entry {
    const WAGRConfigControlDefinition *definition = WAGRConfigControlFind(entry.selectorName.UTF8String);
    if (!definition) return entry.selectorName;
    return [NSString stringWithFormat:@"%@\n%@", [NSString stringWithUTF8String:definition->title], entry.selectorName];
}
- (NSString *)wagrInitialABPropertiesTitle { return [self groupTitle]; }
- (NSString *)wagrABPropertiesTitleForEntryCount:(NSUInteger)entryCount {
    [self updateControlStatus:entryCount];
    return [NSString stringWithFormat:@"%@ (%lu)", [self groupTitle], (unsigned long)entryCount];
}
@end
