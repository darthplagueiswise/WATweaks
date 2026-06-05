#import "WAGRSurface.h"
#import "WAGRRuntimeClassifier.h"
#import <objc/runtime.h>

@implementation WAGREntry @end

static WAGRSurfaceSpec *WAGRMakeSurface(NSString *sid,
                                        NSString *title,
                                        NSString *subtitle,
                                        NSString *icon,
                                        NSArray<NSString *> *names,
                                        NSArray<NSString *> *frags,
                                        NSArray<NSString *> *tokens,
                                        NSArray<NSString *> *cats,
                                        NSArray<NSString *> *imageTokens,
                                        BOOL inst,
                                        BOOL cls,
                                        BOOL props,
                                        BOOL allImage,
                                        BOOL advanced) {
    WAGRSurfaceSpec *s = [WAGRSurfaceSpec new];
    s.surfaceID = sid;
    s.title = title;
    s.subtitle = subtitle ?: @"";
    s.icon = icon ?: @"circle";
    s.classNames = names ?: @[];
    s.classNameFragments = frags ?: @[];
    s.selectorTokens = tokens ?: @[];
    s.categoryAllowList = cats ?: @[];
    s.imagePathTokens = imageTokens ?: @[];
    s.scanInstanceMethods = inst;
    s.scanClassMethods = cls;
    s.scanProperties = props;
    s.scanAllImageClasses = allImage;
    s.advancedOnly = advanced;
    return s;
}

@implementation WAGRSurfaceSpec
+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces {
    return @[
        WAGRMakeSurface(@"exec", @"Runtime Browser — WhatsApp Exec",
                        @"Classes e selectors do executável principal. Patches via WAGRGateStore/MSHookMessageEx.",
                        @"app.dashed",
                        @[@"WAContextMain", @"WAContext", @"WADebugViewController",
                          @"_TtC29WAPrivateExperimentationViews41PrivateExperimentationDebugViewController"],
                        @[@"WA", @"WAPrivate", @"Debug", @"Developer", @"Internal", @"Dogfood", @"Experiment"],
                        @[@"debug", @"developer", @"internal", @"dogfood", @"experiment", @"settings", @"aura", @"subscription", @"liquid", @"glass", @"username", @"eligible"],
                        @[], @[@"/WhatsApp.app/WhatsApp"], YES, YES, YES, YES, YES),

        WAGRMakeSurface(@"sharedmodules", @"Runtime Browser — SharedModules",
                        @"Framework SharedModules: WAAuraGating, WDSLiquidGlass, FOAWAABPropertiesImpl, WAServerProperties.",
                        @"shippingbox.fill",
                        @[@"WAAuraGating", @"WDSLiquidGlass", @"_TtC3WDS14WDSExperiments",
                          @"FOAWAABPropertiesImpl", @"WAABProperties", @"WAServerProperties"],
                        @[@"WA", @"WDS", @"FOA", @"Aura", @"Gating", @"Properties", @"Experiment"],
                        @[@"aura", @"subscription", @"benefit", @"liquid", @"glass", @"wds", @"debug", @"internal", @"eligible", @"enabled"],
                        @[], @[@"SharedModules.framework/SharedModules"], YES, YES, YES, YES, YES),

        WAGRMakeSurface(@"waab", @"WAABProperties",
                        @"AB props / feature flags. Hot path real: FOAWAABPropertiesImpl bool/string/integer/doubleForKey:defaultValue:.",
                        @"switch.2",
                        @[@"WAABProperties", @"FOAWAABPropertiesImpl"],
                        @[@"WAABProperties", @"ABProperties"],
                        @[], @[], @[], YES, YES, YES, NO, YES),

        WAGRMakeSurface(@"context", @"WAContextMain",
                        @"Context services, feature keepers, properties",
                        @"cube.transparent",
                        @[@"WAContextMain", @"WAContext"],
                        @[@"WAContextMain", @"WAContext"],
                        @[], @[], @[], YES, YES, YES, NO, YES),

        WAGRMakeSurface(@"gatekeep", @"Feature Gate Keepers",
                        @"FeatureControlGateKeeper, AccountEligibility and related services",
                        @"shield",
                        @[@"WAFeatureControlGateKeeper", @"WAFeatureKeyManagerStore", @"WAAccountEligibility"],
                        @[@"FeatureControlGateKeeper", @"FeatureKeyManager", @"GateKeeper", @"Gating", @"Eligibility"],
                        @[], @[], @[], YES, YES, YES, NO, YES),

        WAGRMakeSurface(@"liquidglass", @"LiquidGlass / WDS",
                        @"WDSLiquidGlass + WDSExperiments + ios_liquid_glass_* WAAB flags",
                        @"drop.fill",
                        @[@"WDSLiquidGlass", @"_TtC3WDS14WDSExperiments"],
                        @[@"WDSLiquidGlass", @"WDSExperiments", @"LiquidGlass"],
                        @[@"liquid", @"glass", @"wds", @"m0", @"m1", @"m2", @"native", @"unify", @"topbar"],
                        @[@"Liquid Glass"], @[@"SharedModules.framework/SharedModules"], YES, YES, YES, NO, YES),

        WAGRMakeSurface(@"aura", @"WAAuraGating",
                        @"SharedModules Swift/ObjC Aura gates, official simulation flags and providers",
                        @"star",
                        @[@"WAAuraGating", @"WAAuraGating.AuraGating",
                          @"_TtC12WAAuraGating20GatedBenefitProvider",
                          @"_TtC12WAAuraGating25GatedSubscriptionProvider",
                          @"WAABProperties", @"FOAWAABPropertiesImpl"],
                        @[@"WAAuraGating", @"AuraGating", @"AuraBenefit", @"AuraSubscription", @"WAAuraFoundation", @"Aura"],
                        @[@"aura", @"subscription", @"simulation", @"benefit", @"settings", @"eligible", @"active", @"themes", @"icons", @"ringtones"],
                        @[@"WA Plus / Aura"], @[], YES, YES, YES, NO, YES),

        WAGRMakeSurface(@"settings", @"Settings Navigation",
                        @"Settings controllers, rows, internal menus",
                        @"gearshape",
                        @[@"WASettingsViewController", @"WASettingsNavigationController", @"WANewSettingsViewController", @"WASettingsTableViewController"],
                        @[@"WASettings", @"WANewSettings", @"WADebugMenu", @"WADeveloper"],
                        @[], @[], @[], YES, YES, YES, NO, YES),

        WAGRMakeSurface(@"employee", @"Employee / Dogfood",
                        @"Employee, dogfood, internal and debug gates",
                        @"person.badge.key",
                        @[@"WAABProperties", @"WAUserContext", @"WAAccountInfo", @"WAAccountManager", @"WAEmployeeGating", @"WADebugMenuMain", @"WASettingsViewController", @"WAServerProperties"],
                        @[@"Employee", @"Dogfood", @"Internal", @"DebugMenu", @"Developer"],
                        @[], @[], @[], YES, YES, YES, NO, YES),
    ];
}
@end

NSString *WAGRCleanDisplayName(NSString *name) {
    if (!name.length) return @"";
    NSString *s = [name copy];
    while ([s hasPrefix:@"@property "]) s = [s substringFromIndex:10];
    while ([s hasPrefix:@"- "]) s = [s substringFromIndex:2];
    while ([s hasPrefix:@"+ "]) s = [s substringFromIndex:2];
    return s;
}

NSString *WAGRCategoryForSelector(NSString *name) {
    NSString *s = name.lowercaseString ?: @"";
    if ([s containsString:@"aura"] || [s containsString:@"subscri"] || [s containsString:@"premium"] || [s containsString:@"benefit"] || [s containsString:@"plus"]) return @"WA Plus / Aura";
    if ([s containsString:@"liquid"] || [s containsString:@"glass"] || [s containsString:@"wds"]) return @"Liquid Glass";
    if ([s containsString:@"waab"] || [s containsString:@"abproperties"] || [s containsString:@"experiment"] || [s containsString:@"mobileconfig"]) return @"WAAB / Experiments";
    if ([s containsString:@"ai_"] || [s hasPrefix:@"ai"] || [s containsString:@"metaai"] || [s containsString:@"imagine"] || [s containsString:@"hatch"] || [s containsString:@"llama"] || [s containsString:@"bot"] || [s containsString:@"incognito"]) return @"AI / Meta AI";
    if ([s containsString:@"debug"] || [s containsString:@"developer"] || [s containsString:@"internal"] || [s containsString:@"dogfood"] || [s containsString:@"employee"] || [s containsString:@"tester"]) return @"Debug / Internal";
    if ([s containsString:@"settings"] || [s containsString:@"row"] || [s containsString:@"cell"] || [s containsString:@"menu"]) return @"Settings Rows";
    if ([s containsString:@"account"] || [s containsString:@"multi"] || [s containsString:@"eligible"] || [s containsString:@"eligibility"]) return @"Account / Eligibility";
    if ([s containsString:@"privacy"] || [s containsString:@"username"] || [s containsString:@"passkey"] || [s containsString:@"defense"] || [s containsString:@"block"] || [s containsString:@"contact"] || [s containsString:@"online"]) return @"Privacy / Username";
    if ([s containsString:@"business"] || [s containsString:@"smb"] || [s containsString:@"commerce"] || [s containsString:@"paid"]) return @"Premium / Business";
    if ([s containsString:@"call"] || [s containsString:@"voip"] || [s containsString:@"voice"]) return @"Calls";
    if ([s containsString:@"message"] || [s containsString:@"chat"] || [s containsString:@"composer"] || [s containsString:@"thread"] || [s containsString:@"poll"]) return @"Messaging";
    if ([s containsString:@"status"] || [s containsString:@"sticker"] || [s containsString:@"stamp"] || [s containsString:@"viewer"] || [s containsString:@"story"]) return @"Status";
    if ([s containsString:@"channel"] || [s containsString:@"newsletter"] || [s containsString:@"broadcast"]) return @"Status / Channels";
    return @"Other";
}

static BOOL WAGRReturnIsBool(const char *ret) { return ret && (ret[0] == 'B' || ret[0] == 'c'); }

static BOOL WAGRTokenMatch(NSArray<NSString *> *tokens, NSString *haystack) {
    if (!tokens.count) return YES;
    NSString *lo = haystack.lowercaseString ?: @"";
    for (NSString *t in tokens) if (t.length && [lo containsString:t.lowercaseString]) return YES;
    return NO;
}
static BOOL WAGRCategoryAllowed(WAGRSurfaceSpec *spec, NSString *cat) {
    if (!spec.categoryAllowList.count) return YES;
    for (NSString *c in spec.categoryAllowList) if ([c caseInsensitiveCompare:cat] == NSOrderedSame) return YES;
    return NO;
}
static BOOL WAGRClassMatchesImageTokens(Class cls, NSArray<NSString *> *tokens) {
    if (!tokens.count) return YES;
    const char *img = class_getImageName(cls);
    NSString *path = img ? [NSString stringWithUTF8String:img] : @"";
    for (NSString *t in tokens) if (t.length && [path rangeOfString:t options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}
static BOOL WAGRClassNameMatchesFragments(NSString *n, NSArray<NSString *> *frags) {
    if (!frags.count) return NO;
    for (NSString *frag in frags) if (frag.length && [n rangeOfString:frag options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static void WAGRAddEntry(NSMutableArray *out, NSMutableSet *seen, WAGRSurfaceSpec *spec, Class cls, BOOL meta, NSString *selector, BOOL property, NSString *returnType) {
    if (!selector.length || [selector containsString:@":"]) return;
    NSString *cname = NSStringFromClass(cls);
    NSString *display = WAGRCleanDisplayName(selector);
    NSString *semanticCat = WAGRCategoryForSelector([NSString stringWithFormat:@"%@ %@ %@", cname, selector, display]);
    NSString *runtimeCat = WAGRRuntimeSectionForSelector(selector, cname);
    NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@", cname, selector, semanticCat, runtimeCat];
    if (!WAGRTokenMatch(spec.selectorTokens, hay)) return;
    if (!WAGRCategoryAllowed(spec, semanticCat)) return;
    NSString *uid = [NSString stringWithFormat:@"%@.%d.%@", cname, meta, selector];
    if ([seen containsObject:uid]) return;
    [seen addObject:uid];
    WAGREntry *e = [WAGREntry new];
    e.surfaceID = spec.surfaceID ?: @"runtime";
    e.className = cname;
    e.isClassMethod = meta;
    e.isProperty = property;
    e.selectorName = selector;
    e.displayName = display;
    e.returnType = returnType ?: @"BOOL";
    e.category = runtimeCat ?: semanticCat ?: @"Other";
    e.overrideKey = selector;
    [out addObject:e];
}

@implementation WAGRScanner
+ (NSArray<WAGREntry *> *)scanSurface:(WAGRSurfaceSpec *)spec {
    if (!spec) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *classesToScan = [NSMutableArray array];

    for (NSString *n in spec.classNames) {
        Class c = NSClassFromString(n) ?: objc_getClass(n.UTF8String);
        if (c && WAGRClassMatchesImageTokens(c, spec.imagePathTokens) && ![classesToScan containsObject:c]) [classesToScan addObject:c];
    }

    if (spec.classNameFragments.count || spec.scanAllImageClasses) {
        unsigned int total = 0;
        Class *all = objc_copyClassList(&total);
        if (all) {
            for (unsigned int i = 0; i < total; i++) {
                Class c = all[i];
                if (!WAGRClassMatchesImageTokens(c, spec.imagePathTokens)) continue;
                NSString *n = NSStringFromClass(c);
                if (!spec.scanAllImageClasses && !WAGRClassNameMatchesFragments(n, spec.classNameFragments)) continue;
                if (![classesToScan containsObject:c]) [classesToScan addObject:c];
            }
            free(all);
        }
    }

    for (Class cls in classesToScan) {
        if (spec.scanProperties) {
            unsigned int pc = 0; objc_property_t *props = class_copyPropertyList(cls, &pc);
            if (props) {
                for (unsigned int i = 0; i < pc; i++) {
                    const char *pn = property_getName(props[i]); const char *attrs = property_getAttributes(props[i]);
                    if (!pn || !attrs) continue;
                    NSString *attr = @(attrs);
                    if (![attr hasPrefix:@"TB"] && ![attr hasPrefix:@"Tc"]) continue;
                    NSString *sel = @(pn);
                    Method m = class_getInstanceMethod(cls, NSSelectorFromString(sel));
                    if (!m || method_getNumberOfArguments(m) != 2) continue;
                    WAGRAddEntry(out, seen, spec, cls, NO, sel, YES, @"BOOL");
                }
                free(props);
            }
        }
        for (int meta = 0; meta <= 1; meta++) {
            if (meta == 0 && !spec.scanInstanceMethods) continue;
            if (meta == 1 && !spec.scanClassMethods) continue;
            Class target = meta ? object_getClass(cls) : cls;
            unsigned int n = 0; Method *ms = class_copyMethodList(target, &n);
            if (!ms) continue;
            for (unsigned int i = 0; i < n; i++) {
                if (method_getNumberOfArguments(ms[i]) != 2) continue;
                char ret[8] = {0}; method_getReturnType(ms[i], ret, sizeof(ret));
                if (!WAGRReturnIsBool(ret)) continue;
                NSString *sel = NSStringFromSelector(method_getName(ms[i]));
                WAGRAddEntry(out, seen, spec, cls, (BOOL)meta, sel, NO, @"BOOL");
            }
            free(ms);
        }
    }
    return [out sortedArrayUsingComparator:^NSComparisonResult(WAGREntry *a, WAGREntry *b) {
        NSComparisonResult r = [a.category localizedCaseInsensitiveCompare:b.category];
        if (r != NSOrderedSame) return r;
        r = [a.className localizedCaseInsensitiveCompare:b.className];
        if (r != NSOrderedSame) return r;
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
}
@end
