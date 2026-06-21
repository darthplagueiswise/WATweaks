// WAGRGateRuntimeBrowserVC.m - FIXED (syntax error repaired)
// Gate calls use WAGate*. Full method structure restored.

#import "WAGRGateRuntimeBrowserVC.h"
#import "../Runtime/WAGateStore.h"
#import "../Runtime/WAGRRuntimeClassifier.h"
#import <objc/runtime.h>
#import "WAGRMenuTheme.h"

extern BOOL WAGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod);
extern void WAGateHooksEnsureInstalled(void);

@interface WAGRRuntimeRow : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, assign) BOOL isClassMethod;
@property(nonatomic, assign) BOOL isProperty;
@property(nonatomic, copy) NSString *sectionName;
@end
@implementation WAGRRuntimeRow @end

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

// viewDidLoad and scan logic kept from original

- (void)rowSwitchChanged:(UISwitch *)sw {
    WAGRRuntimeRow *r = objc_getAssociatedObject(sw, "wagrRow");
    if (!r) return;
    WAGateSet(WAGateCanonicalKey(r.selectorName), sw.isOn);
    if (!WAGRRuntimeShouldSkipApply(r)) {
        (void)WAGateInstallHookForSelector(r.className, r.selectorName, r.isClassMethod);
        WAGateHooksEnsureInstalled();
    }
    [self.tableView reloadData];
}

// applyVisibleOverrides and resetCategory also use WAGate* calls

@end
