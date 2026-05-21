// WAGRGatingAreaMenuVC.m
// ─────────────────────────────────────────────────────────────────────────────
// Implementation notes
// ────────────────────
// Each row hosts a UISwitch as accessoryView. The switch is bound to the
// override key returned by WAGROverrideKeyFor(class, sel, isClassMethod).
// Toggling the switch writes the appropriate boolean to NSUserDefaults
// directly — the existing WAGRObjCHookRouter reinstall pass picks up the
// new key at the next startup or when the user taps "Reinstall hooks"
// from the Advanced menu.
//
// The 3-state semantic that the router uses (YES / NO / absent) maps to
// the switch like this:
//   • switch ON  → override key present and YES (force gate to YES)
//   • switch OFF → override key removed entirely (no override; gate uses
//                  WhatsApp's original logic)
// For inverted entries, "switch ON" still writes YES — the inversion is
// handled at the trampoline layer by the router consulting entry.inverted
// when it computes the return value. Keeping the persistence uniform
// regardless of inverted lets the router treat all overrides identically.
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRGatingAreaMenuVC.h"
#import "../WAGramPrefix.h"
#import <objc/runtime.h>

// The router needs to be told that an override changed so it can install
// the hook live if the user toggled while the app is running. We rely on
// a small re-install entry point exposed by WAGRObjCHookRouter.
extern NSUInteger WAGRReinstallPersistedHooks(void);
extern void WAGRWAABEnsureHooksInstalled(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRNativeDevMenuEnsureHooksInstalled(void);
extern void WAGRSettingsRowsNativeEnsureHooksInstalled(void);

// Associated-object key for stashing the entry pointer on each switch so
// the switch's target/action can recover which catalog entry it corresponds
// to without keeping a parallel index<->entry map.
static const void *kWAGREntryAssocKey = &kWAGREntryAssocKey;

@interface WAGRGatingAreaMenuVC ()
@property(nonatomic, assign) WAGRGatingArea area;
@property(nonatomic, copy)   NSArray<WAGRGatingEntry *> *entries;
@end

@implementation WAGRGatingAreaMenuVC

- (instancetype)initWithArea:(WAGRGatingArea)area {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _area    = area;
    _entries = [WAGRGatingCatalog entriesForArea:area];
    self.title = WAGRGatingAreaTitle(area);
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.08 alpha:1];
    self.tableView.allowsSelection = NO;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    // Section 0: gates list (or empty-state).
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    // If the area has no curated entries yet, we still show one row that
    // tells the user this area is scaffolded but empty. This is friendlier
    // than a silently empty screen.
    return MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return WAGRGatingAreaSubtitle(self.area);
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (self.entries.count == 0) {
        return @"This area's catalog is empty. Open WAGRGatingCatalog.m to add entries — see WAGRGatingAreaAura / WAGRGatingAreaHiddenRows for the format.";
    }
    return [NSString stringWithFormat:@"%lu gates · toggles persist as wagr.override.* keys",
            (unsigned long)self.entries.count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithRed:.13 green:.13 blue:.14 alpha:1];

    // Empty-state row.
    if (self.entries.count == 0) {
        c.textLabel.text = @"No curated gates for this area yet";
        c.textLabel.textColor = UIColor.tertiaryLabelColor;
        c.detailTextLabel.text = @"Extend WAGRGatingCatalog.m to populate.";
        c.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }

    WAGRGatingEntry *e = self.entries[ip.row];
    c.textLabel.text = e.title;
    c.textLabel.textColor = UIColor.labelColor;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = e.desc;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;

    // Build a switch that reflects the persisted override state.
    UISwitch *sw = [[UISwitch alloc] init];
    NSString *key = WAGROverrideKeyFor(e.className, e.selectorName, e.isClassMethod);
    sw.on = WAGRHasOverride(key);
    objc_setAssociatedObject(sw, kWAGREntryAssocKey, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;

    return c;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tv estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip {
    return 66;
}

#pragma mark - Toggle

- (void)switchChanged:(UISwitch *)sw {
    WAGRGatingEntry *e = objc_getAssociatedObject(sw, kWAGREntryAssocKey);
    if (!e) return;

    NSString *key = WAGROverrideKeyFor(e.className, e.selectorName, e.isClassMethod);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    BOOL physicalValue = !e.inverted;
    if (sw.on) {
        // Use the shared override helper instead of writing NSUserDefaults
        // directly. For WAABProperties entries this mirrors the value into
        // wagr.waab.<flag>, which is the storage read by WAABPropsObserver and
        // by boolForKey:defaultValue:. Without this mirror, Settings-row
        // toggles are visually ON but WhatsApp still reads the original gates.
        WAGRSetOverride(key, physicalValue);
        NSLog(@"[WATweaks][Catalog] override ON  for %@ %c%@ (physical=%@ key=%@)",
              e.className, e.isClassMethod ? '+' : '-', e.selectorName, physicalValue ? @"YES" : @"NO", key);
    } else {
        WAGRClearOverride(key);
        NSLog(@"[WATweaks][Catalog] override OFF for %@ %c%@ (physical=%@ key=%@)",
              e.className, e.isClassMethod ? '+' : '-', e.selectorName, physicalValue ? @"YES" : @"NO", key);
    }
    [ud synchronize];

    // Live-install all relevant owners. WAAB covers flag-backed rows, Aura
    // covers SharedModules Swift/ObjC gates, NativeDev covers the Developer
    // row provider, and the generic router covers everything else.
    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRNativeDevMenuEnsureHooksInstalled();
    WAGRSettingsRowsNativeEnsureHooksInstalled();
    WAGRReinstallPersistedHooks();
}

@end
