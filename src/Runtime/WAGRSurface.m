// WAGRSurface.m — real runtime surfaces backed by current Mach-O images.
// Runtime browsers are intentionally technical: group by Objective-C class and
// expose only patchable BOOL/char no-argument getters with a toggle.

#import "WAGRSurface.h"
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
                                        BOOL inst,
                                        BOOL cls,
                                        BOOL props,
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
    s.scanInstanceMethods = inst;
    s.scanClassMethods = cls;
    s.scanProperties = props;
    s.advancedOnly = advanced;
    return s;
}

@implementation WAGRSurfaceSpec

+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces {
    return @[
        WAGRMakeSurface(@"exec", @"Runtime — WhatsApp Executable",
                        @"Classes do executável principal WhatsApp.app/WhatsApp",
                        @"app.dashed", @[], @[], @[], @[], YES, YES, YES, YES),

        WAGRMakeSurface(@"sharedmodules", @"Runtime — SharedModules.framework",
                        @"Classes do Frameworks/SharedModules.framework/SharedModules",
                        @"shippingbox", @[], @[], @[], @[], YES, YES, YES, YES),

        WAGRMakeSurface(@"waab", @"WAABProperties",
                        @"AB props / feature flags",
                        @"switch.2",
                        @[@"WAABProperties", @"FOAWAABPropertiesImpl", @"WAABPropertiesPreChatd"],
                        @[@"WAABProperties", @"ABProperties", @"FOAWAAB"],
                        @[], @[], YES, YES, YES, YES),

        WAGRMakeSurface(@"aura", @"WAAuraGating",
                        @"Aura / WA Plus gates",
                        @"star",
                        @[@"WAAuraGating"],
                        @[@"WAAuraGating", @"AuraGating", @"AuraBenefit", @"AuraSubscription", @"Aura"],
                        @[@"aura", @"subscription", @"benefit", @"theme", @"icon", @"ringtone", @"sticker"],
                        @[], YES, YES, YES, YES),

        WAGRMakeSurface(@"liquidglass", @"LiquidGlass / WDS",
                        @"LiquidGlass gates and WDSLiquidGlass class methods",
                        @"drop",
                        @[@"WDSLiquidGlass", @"WAABProperties", @"FOAWAABPropertiesImpl"],
                        @[@"LiquidGlass", @"WDSLiquidGlass"],
                        @[@"liquid", @"glass", @"wds", @"M0", @"M1", @"M2"],
                        @[], YES, YES, YES, YES),
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
    // Compatibility symbol. Runtime UI now groups by class, not synthetic category.
    return name.length ? name : @"Other";
}

static BOOL WAGRReturnIsPatchableBool(const char *ret) {
    return ret && (ret[0] == 'B' || ret[0] == 'c');
}

static BOOL WAGRTokenMatch(NSArray<NSString *> *tokens, NSString *haystack) {
    if (!tokens.count) return YES;
    NSString *lo = haystack.lowercaseString ?: @"";
    for (NSString *t in tokens) {
        if (t.length && [lo containsString:t.lowercaseString]) return YES;
    }
    return NO;
}

static BOOL WAGRSurfaceIsImageBacked(WAGRSurfaceSpec *spec) {
    NSString *sid = spec.surfaceID.lowercaseString ?: @"";
    return [sid isEqualToString:@"exec"] || [sid isEqualToString:@"sharedmodules"];
}

static BOOL WAGRSurfaceClassMatchesImage(WAGRSurfaceSpec *spec, Class cls) {
    if (!spec || !cls) return NO;
    NSString *sid = spec.surfaceID.lowercaseString ?: @"";
    const char *img = class_getImageName(cls);
    NSString *path = img ? [NSString stringWithUTF8String:img] : @"";
    if (!path.length) return NO;

    if ([sid isEqualToString:@"sharedmodules"]) {
        return [path rangeOfString:@"SharedModules.framework/SharedModules" options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    if ([sid isEqualToString:@"exec"]) {
        BOOL wa = [path rangeOfString:@"/WhatsApp.app/WhatsApp" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                  [path hasSuffix:@"/WhatsApp"] || [path isEqualToString:@"WhatsApp"];
        BOOL fw = [path rangeOfString:@".framework/" options:NSCaseInsensitiveSearch].location != NSNotFound;
        return wa && !fw;
    }
    return YES;
}

static void WAGRAddEntry(NSMutableArray<WAGREntry *> *out,
                         NSMutableSet<NSString *> *seen,
                         WAGRSurfaceSpec *spec,
                         Class cls,
                         BOOL meta,
                         NSString *selector,
                         BOOL property,
                         NSString *returnType) {
    if (!selector.length || [selector containsString:@":"]) return;
    NSString *cname = NSStringFromClass(cls);
    if (!cname.length) return;
    NSString *display = WAGRCleanDisplayName(selector);
    NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", cname, selector, display ?: @""];
    if (!WAGRTokenMatch(spec.selectorTokens, hay)) return;

    NSString *uid = [NSString stringWithFormat:@"%@|%@|%@", cname, meta ? @"class" : @"inst", selector];
    if ([seen containsObject:uid]) return;
    [seen addObject:uid];

    WAGREntry *e = [WAGREntry new];
    e.surfaceID = spec.surfaceID ?: @"runtime";
    e.className = cname;
    e.isClassMethod = meta;
    e.isProperty = property;
    e.selectorName = selector;
    e.displayName = display.length ? display : selector;
    e.returnType = returnType ?: @"BOOL";
    e.category = cname;       // critical: group only by class
    e.overrideKey = selector; // single unified GateStore key
    [out addObject:e];
}

@implementation WAGRScanner

+ (NSArray<WAGREntry *> *)scanSurface:(WAGRSurfaceSpec *)spec {
    if (!spec) return @[];
    NSMutableArray<WAGREntry *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<Class> *classesToScan = [NSMutableArray array];

    void (^addClass)(Class) = ^(Class c) {
        if (!c) return;
        if (WAGRSurfaceIsImageBacked(spec) && !WAGRSurfaceClassMatchesImage(spec, c)) return;
        if (![classesToScan containsObject:c]) [classesToScan addObject:c];
    };

    for (NSString *n in spec.classNames) addClass(NSClassFromString(n));

    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (all) {
        for (unsigned int i = 0; i < total; i++) {
            Class c = all[i];
            NSString *name = NSStringFromClass(c) ?: @"";
            if (WAGRSurfaceIsImageBacked(spec)) {
                addClass(c);
                continue;
            }
            for (NSString *frag in spec.classNameFragments) {
                if (frag.length && [name rangeOfString:frag options:NSCaseInsensitiveSearch].location != NSNotFound) { addClass(c); break; }
            }
        }
        free(all);
    }

    for (Class cls in classesToScan) {
        if (spec.scanProperties) {
            unsigned int pc = 0;
            objc_property_t *props = class_copyPropertyList(cls, &pc);
            if (props) {
                for (unsigned int i = 0; i < pc; i++) {
                    const char *pn = property_getName(props[i]);
                    const char *attrs = property_getAttributes(props[i]);
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
            unsigned int n = 0;
            Method *ms = class_copyMethodList(target, &n);
            if (!ms) continue;
            for (unsigned int i = 0; i < n; i++) {
                if (method_getNumberOfArguments(ms[i]) != 2) continue;
                char ret[16] = {0};
                method_getReturnType(ms[i], ret, sizeof(ret));
                if (!WAGRReturnIsPatchableBool(ret)) continue;
                NSString *sel = NSStringFromSelector(method_getName(ms[i]));
                WAGRAddEntry(out, seen, spec, cls, (BOOL)meta, sel, NO, @"BOOL");
            }
            free(ms);
        }
    }

    return [out sortedArrayUsingComparator:^NSComparisonResult(WAGREntry *a, WAGREntry *b) {
        NSComparisonResult r = [a.className localizedCaseInsensitiveCompare:b.className];
        if (r != NSOrderedSame) return r;
        r = [a.selectorName localizedCaseInsensitiveCompare:b.selectorName];
        if (r != NSOrderedSame) return r;
        return a.isClassMethod == b.isClassMethod ? NSOrderedSame : (a.isClassMethod ? NSOrderedAscending : NSOrderedDescending);
    }];
}

@end
