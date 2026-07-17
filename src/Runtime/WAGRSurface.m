#import "WAGRSurface.h"
#import "WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#include <stdlib.h>

@implementation WAGREntry
@end

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
    WAGRSurfaceSpec *surface = [WAGRSurfaceSpec new];
    surface.surfaceID = sid;
    surface.title = title;
    surface.subtitle = subtitle ?: @"";
    surface.icon = icon ?: @"circle";
    surface.classNames = names ?: @[];
    surface.classNameFragments = frags ?: @[];
    surface.selectorTokens = tokens ?: @[];
    surface.categoryAllowList = cats ?: @[];
    surface.scanInstanceMethods = inst;
    surface.scanClassMethods = cls;
    surface.scanProperties = props;
    surface.advancedOnly = advanced;
    return surface;
}

@implementation WAGRSurfaceSpec

+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces {
    return @[
        WAGRMakeSurface(@"waab", @"WAABProperties — atual",
                        @"AB props tipadas carregadas nesta build",
                        @"switch.2",
                        @[@"WAABProperties", @"FOAWAABPropertiesImpl", @"WAABPropertiesPreChatd",
                          @"WAFoundation.FOAWAABPropertiesImpl"],
                        @[@"WAABProperties", @"ABProperties", @"FOAWAAB", @"ObjCABProps"],
                        @[], @[], YES, YES, YES, NO),

        WAGRMakeSurface(@"privateexperimentation", @"Private Experimentation",
                        @"Managers, providers, properties e debug UI",
                        @"testtube.2",
                        @[], @[@"PrivateExperiment", @"Experimentation", @"PrivateABPropert"],
                        @[], @[], YES, YES, YES, NO),

        WAGRMakeSurface(@"debugmenu", @"Developer / Debug Menu",
                        @"Gates e providers do menu nativo",
                        @"hammer",
                        @[@"_TtC15WADebugMenuMain17DebugMenuProvider", @"WADebugViewController"],
                        @[@"DebugMenu", @"WADebug"],
                        @[], @[], YES, YES, YES, NO),

        WAGRMakeSurface(@"mobileconfig", @"MobileConfig",
                        @"Readers, contexts e gates ObjC/Swift",
                        @"slider.horizontal.3",
                        @[], @[@"MobileConfig", @"WAMobileConfig", @"FOAMobileConfig"],
                        @[], @[], YES, YES, YES, NO),

        WAGRMakeSurface(@"aura", @"WAAuraGating",
                        @"Aura / WA Plus gates",
                        @"star",
                        @[@"WAAuraGating"],
                        @[@"WAAuraGating", @"AuraGating", @"AuraBenefit", @"AuraSubscription", @"Aura"],
                        @[@"aura", @"subscription", @"benefit", @"theme", @"icon", @"ringtone", @"sticker"],
                        @[], YES, YES, YES, NO),

        WAGRMakeSurface(@"liquidglass", @"LiquidGlass / WDS",
                        @"LiquidGlass gates e valores tipados",
                        @"drop",
                        @[@"WDSLiquidGlass", @"WAABProperties", @"FOAWAABPropertiesImpl"],
                        @[@"LiquidGlass", @"WDSLiquidGlass"],
                        @[@"liquid", @"glass", @"wds", @"M0", @"M1", @"M2"],
                        @[], YES, YES, YES, NO),

        WAGRMakeSurface(@"exec", @"Runtime — WhatsApp Executable",
                        @"Browser bruto tipado do executable principal",
                        @"app.dashed", @[], @[], @[], @[], YES, YES, YES, YES),

        WAGRMakeSurface(@"sharedmodules", @"Runtime — SharedModules.framework",
                        @"Browser bruto tipado do framework compartilhado",
                        @"shippingbox", @[], @[], @[], @[], YES, YES, YES, YES)
    ];
}

@end

NSString *WAGRCleanDisplayName(NSString *name) {
    if (!name.length) return @"";
    NSString *value = [name copy];
    while ([value hasPrefix:@"@property "]) value = [value substringFromIndex:10];
    while ([value hasPrefix:@"- "]) value = [value substringFromIndex:2];
    while ([value hasPrefix:@"+ "]) value = [value substringFromIndex:2];
    return value;
}

NSString *WAGRCategoryForSelector(NSString *name) {
    return name.length ? name : @"Other";
}

static BOOL WAGRTokenMatch(NSArray<NSString *> *tokens, NSString *haystack) {
    if (!tokens.count) return YES;
    NSString *lower = haystack.lowercaseString ?: @"";
    for (NSString *token in tokens) {
        if (token.length && [lower containsString:token.lowercaseString]) return YES;
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
    const char *image = class_getImageName(cls);
    NSString *path = image ? [NSString stringWithUTF8String:image] : @"";
    if (!path.length) return NO;
    if ([sid isEqualToString:@"sharedmodules"]) {
        return [path rangeOfString:@"SharedModules.framework/SharedModules" options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    if ([sid isEqualToString:@"exec"]) {
        BOOL whatsapp = [path rangeOfString:@"/WhatsApp.app/WhatsApp" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                         [path hasSuffix:@"/WhatsApp"] || [path isEqualToString:@"WhatsApp"];
        BOOL framework = [path rangeOfString:@".framework/" options:NSCaseInsensitiveSearch].location != NSNotFound;
        return whatsapp && !framework;
    }
    return YES;
}

static void WAGRAddEntry(NSMutableArray<WAGREntry *> *output,
                         NSMutableSet<NSString *> *seen,
                         WAGRSurfaceSpec *spec,
                         Class cls,
                         BOOL meta,
                         NSString *selector,
                         BOOL property,
                         NSString *typeCode) {
    if (!selector.length || [selector containsString:@":"] || !typeCode.length) return;
    NSString *typeName = WAGRRuntimeValueTypeName(typeCode);
    if (!typeName.length) return;
    NSString *className = NSStringFromClass(cls);
    if (!className.length) return;
    NSString *display = WAGRCleanDisplayName(selector);
    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@", className, selector, display, typeName];
    if (!WAGRTokenMatch(spec.selectorTokens, haystack)) return;

    NSString *uid = WAGRRuntimeValueUID(className, selector, meta);
    if (!uid.length || [seen containsObject:uid]) return;
    [seen addObject:uid];

    WAGREntry *entry = [WAGREntry new];
    entry.surfaceID = spec.surfaceID ?: @"runtime";
    entry.className = className;
    entry.isClassMethod = meta;
    entry.isProperty = property;
    entry.selectorName = selector;
    entry.displayName = display.length ? display : selector;
    entry.returnType = typeName;
    entry.typeCode = typeCode;
    entry.typeName = typeName;
    entry.category = className;
    entry.overrideKey = uid;
    [output addObject:entry];
}

@implementation WAGRScanner

+ (NSArray<WAGREntry *> *)scanSurface:(WAGRSurfaceSpec *)spec {
    if (!spec) return @[];
    NSMutableArray<WAGREntry *> *output = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableOrderedSet *classesToScan = [NSMutableOrderedSet orderedSet];

    void (^addClass)(Class) = ^(Class cls) {
        if (!cls) return;
        if (WAGRSurfaceIsImageBacked(spec) && !WAGRSurfaceClassMatchesImage(spec, cls)) return;
        [classesToScan addObject:cls];
    };

    for (NSString *name in spec.classNames) addClass(NSClassFromString(name) ?: objc_getClass(name.UTF8String));

    int total = objc_getClassList(NULL, 0);
    if (total > 0) {
        __unsafe_unretained Class *all = (__unsafe_unretained Class *)calloc((size_t)total, sizeof(Class));
        if (all) {
            total = objc_getClassList(all, total);
            for (int index = 0; index < total; index++) {
                Class cls = all[index];
                NSString *name = NSStringFromClass(cls) ?: @"";
                if (WAGRSurfaceIsImageBacked(spec)) {
                    addClass(cls);
                    continue;
                }
                for (NSString *fragment in spec.classNameFragments) {
                    if (fragment.length && [name rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        addClass(cls);
                        break;
                    }
                }
            }
            free(all);
        }
    }

    for (Class cls in classesToScan) {
        if (spec.scanProperties) {
            unsigned int propertyCount = 0;
            objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
            if (properties) {
                for (unsigned int index = 0; index < propertyCount; index++) {
                    const char *name = property_getName(properties[index]);
                    if (!name) continue;
                    NSString *selector = [NSString stringWithUTF8String:name];
                    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selector));
                    if (!method || method_getNumberOfArguments(method) != 2) continue;
                    char type[64] = {0};
                    method_getReturnType(method, type, sizeof(type));
                    WAGRAddEntry(output, seen, spec, cls, NO, selector, YES,
                                 [NSString stringWithUTF8String:type] ?: @"");
                }
                free(properties);
            }
        }

        for (NSUInteger meta = 0; meta <= 1; meta++) {
            if (meta == 0 && !spec.scanInstanceMethods) continue;
            if (meta == 1 && !spec.scanClassMethods) continue;
            Class owner = meta ? object_getClass(cls) : cls;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            if (!methods) continue;
            for (unsigned int index = 0; index < methodCount; index++) {
                Method method = methods[index];
                if (method_getNumberOfArguments(method) != 2) continue;
                char type[64] = {0};
                method_getReturnType(method, type, sizeof(type));
                NSString *typeCode = [NSString stringWithUTF8String:type] ?: @"";
                if (!WAGRRuntimeValueTypeIsSupported(typeCode)) continue;
                NSString *selector = NSStringFromSelector(method_getName(method));
                WAGRAddEntry(output, seen, spec, cls, (BOOL)meta, selector, NO, typeCode);
            }
            free(methods);
        }
    }

    return [output sortedArrayUsingComparator:^NSComparisonResult(WAGREntry *left, WAGREntry *right) {
        NSComparisonResult result = [left.className localizedCaseInsensitiveCompare:right.className];
        if (result != NSOrderedSame) return result;
        result = [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
        if (result != NSOrderedSame) return result;
        return left.isClassMethod == right.isClassMethod ? NSOrderedSame : (left.isClassMethod ? NSOrderedAscending : NSOrderedDescending);
    }];
}

@end
