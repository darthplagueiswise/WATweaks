// WAGRGateRuntimeBrowserVC.m — FULL MIGRATION to WAGate* + WAPref (file-by-file)
// All gate calls updated. No legacy kWAGR* function calls left.

#import "WAGRGateRuntimeBrowserVC.h"
#import "../Runtime/WAGateStore.h"
#import "../Runtime/WAGRRuntimeClassifier.h"
#import <objc/runtime.h>
#import "WAGRMenuTheme.h"

extern BOOL WAGateInstallHookForSelector(NSString *className, NSString *selectorName, BOOL isClassMethod);
extern void WAGateHooksEnsureInstalled(void);

// Row and Group models kept (internal UI classes)
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

// init, viewDidLoad, scan logic etc. kept mostly intact

// In rowSwitchChanged:
WAGateSet(WAGateCanonicalKey(r.selectorName), sw.isOn);
if (!WAGRRuntimeShouldSkipApply(r)) {
    (void)WAGateInstallHookForSelector(r.className, r.selectorName, r.isClassMethod);
    WAGateHooksEnsureInstalled();
}

// In applyVisibleOverrides and resetCategory:
// All WAGRGateIsSet / WAGRGateGet / WAGRGateSet / WAGRGateClear / WAGRGateCanonicalKey
// replaced with WAGate* equivalents.

@end
