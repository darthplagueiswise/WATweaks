#import "WAGRFeatureState.h"
#import "WAGRRuntimeValueStore.h"
#import "WAGRABPropsRuntime.h"
#import "WAGRABPropsNativeStore.h"

#import <objc/runtime.h>
#include <string.h>

extern id WAGRCurrentUserContext(void);

NSDictionary *WAGRFeatureTarget(NSString *className, BOOL classMethod) {
    return @{ @"class" : className ?: @"", @"meta" : @(classMethod) };
}

NSArray<NSDictionary *> *WAGRFeatureDefaultWAABTargets(void) {
    static NSArray *targets = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        targets = @[
            WAGRFeatureTarget(@"WAABProperties", NO),
            WAGRFeatureTarget(@"FOAWAABPropertiesImpl", NO),
            WAGRFeatureTarget(@"WAFoundation.FOAWAABPropertiesImpl", NO),
        ];
    });
    return targets;
}

static NSArray<NSDictionary *> *WAGRFeatureTargets(NSArray<NSDictionary *> *targets) {
    return targets.count ? targets : WAGRFeatureDefaultWAABTargets();
}

static NSObject *WAGRFeatureStateLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static const char *WAGRFeatureSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static NSString *WAGRFeatureMethodType(Class cls, NSString *selectorName, BOOL meta) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = meta ? class_getClassMethod(cls, selector)
                         : class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRFeatureSkipQualifiers(raw);
    if (!*type) return nil;
    NSString *normalized = [NSString stringWithFormat:@"%c", *type];
    if (!WAGRRuntimeValueTypeIsBoolean(normalized) &&
        !WAGRRuntimeValueTypeIsSignedInteger(normalized) &&
        !WAGRRuntimeValueTypeIsUnsignedInteger(normalized)) return nil;
    return normalized;
}

static id WAGRFeatureExactReceiver(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    for (id object in WAGRABPropsResolveRuntimeObjects(WAGRCurrentUserContext())) {
        if ([object isKindOfClass:cls] && [object respondsToSelector:selector]) return object;
    }
    return nil;
}

static BOOL WAGRFeatureParseBool(id raw, BOOL *outValue) {
    if (!raw || raw == NSNull.null) return NO;
    if ([raw isKindOfClass:NSNumber.class]) {
        if (outValue) *outValue = [raw boolValue];
        return YES;
    }
    if (![raw isKindOfClass:NSString.class]) return NO;
    NSString *lower = [(NSString *)raw lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] ||
        [lower isEqualToString:@"yes"] || [lower isEqualToString:@"on"]) {
        if (outValue) *outValue = YES;
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] ||
        [lower isEqualToString:@"no"] || [lower isEqualToString:@"off"]) {
        if (outValue) *outValue = NO;
        return YES;
    }
    return NO;
}

static NSDictionary<NSString *, NSNumber *> *WAGRFeatureNameToCode(void) {
    static NSDictionary<NSString *, NSNumber *> *cached = nil;
    static NSString *cachedFingerprint = nil;
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(NULL);
    if (!snapshot) return cached ?: @{};

    @synchronized (WAGRFeatureStateLock()) {
        NSString *fingerprint = snapshot.fingerprint ?: @"";
        if (cached && [cachedFingerprint isEqualToString:fingerprint]) return cached;

        NSDictionary *document = WAGRABPropsNativeExportDocument(snapshot);
        NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class] ? document[@"entries"] : @[];
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (id object in entries) {
            if (![object isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *entry = object;
            NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : nil;
            NSUInteger numericCode = [entry[@"code"] respondsToSelector:@selector(unsignedIntegerValue)]
                ? [entry[@"code"] unsignedIntegerValue] : 0;
            if (name.length && numericCode && !map[name]) map[name] = @(numericCode);
        }
        cached = [map copy];
        cachedFingerprint = [fingerprint copy];
        return cached;
    }
}

NSUInteger WAGRFeatureResolvedABID(NSString *selectorName, NSUInteger fallbackStableID) {
    NSNumber *code = selectorName.length ? WAGRFeatureNameToCode()[selectorName] : nil;
    NSUInteger resolved = code.unsignedIntegerValue;
    return resolved ? resolved : fallbackStableID;
}

static BOOL WAGRFeatureNativeBool(NSUInteger stableID, BOOL *outValue) {
    if (!stableID) return NO;
    WAGRABPropsNativeSnapshot *snapshot = WAGRABPropsReadNativeSnapshot(NULL);
    id node = snapshot.props[[NSString stringWithFormat:@"%lu", (unsigned long)stableID]];
    if ([node isKindOfClass:NSDictionary.class]) {
        id value = node[@"value"] ?: node[@"default"];
        return WAGRFeatureParseBool(value, outValue);
    }
    return WAGRFeatureParseBool(node, outValue);
}

static BOOL WAGRFeatureClassLooksLikeABProperties(NSString *className) {
    NSString *lower = className.lowercaseString ?: @"";
    return [lower containsString:@"abpropert"] || [lower containsString:@"foawaab"];
}

static BOOL WAGRFeatureOverrideForSelector(NSString *selectorName,
                                           NSArray<NSDictionary *> *targets,
                                           BOOL *outValue) {
    if (!selectorName.length) return NO;
    NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();
    NSArray *resolvedTargets = WAGRFeatureTargets(targets);

    for (NSDictionary *target in resolvedTargets) {
        NSString *wantedClass = [target[@"class"] isKindOfClass:NSString.class] ? target[@"class"] : @"";
        BOOL wantedMeta = [target[@"meta"] boolValue];
        for (NSDictionary *spec in specs) {
            NSString *specSelector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
            NSString *specClass = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
            if (![specSelector isEqualToString:selectorName] || ![specClass isEqualToString:wantedClass] ||
                [spec[@"meta"] boolValue] != wantedMeta) continue;
            id value = WAGRRuntimeValueOverride(wantedClass, selectorName, wantedMeta);
            if (WAGRFeatureParseBool(value, outValue)) return YES;
        }
    }

    for (NSDictionary *spec in specs) {
        NSString *specSelector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        if (![specSelector isEqualToString:selectorName] || !WAGRFeatureClassLooksLikeABProperties(className)) continue;
        id value = WAGRRuntimeValueOverride(className, selectorName, [spec[@"meta"] boolValue]);
        if (WAGRFeatureParseBool(value, outValue)) return YES;
    }
    return NO;
}

BOOL WAGRFeatureReadBool(NSString *selectorName,
                         NSArray<NSDictionary *> *targets,
                         NSUInteger fallbackStableID,
                         BOOL *outValue,
                         WAGRFeatureStateSource *outSource) {
    if (outSource) *outSource = WAGRFeatureStateSourceUnavailable;
    if (!selectorName.length) return NO;

    BOOL value = NO;
    if (WAGRFeatureOverrideForSelector(selectorName, targets, &value)) {
        if (outValue) *outValue = value;
        if (outSource) *outSource = WAGRFeatureStateSourceOverride;
        return YES;
    }

    for (NSDictionary *target in WAGRFeatureTargets(targets)) {
        NSString *className = [target[@"class"] isKindOfClass:NSString.class] ? target[@"class"] : nil;
        BOOL meta = [target[@"meta"] boolValue];
        Class cls = className.length ? (NSClassFromString(className) ?: objc_getClass(className.UTF8String)) : Nil;
        NSString *type = WAGRFeatureMethodType(cls, selectorName, meta);
        if (!type.length) continue;
        id receiver = meta ? (id)cls : WAGRFeatureExactReceiver(cls, selectorName);
        if (!meta && !receiver) continue;
        id raw = nil;
        (void)WAGRRuntimeValueRead(className, selectorName, meta, receiver, &raw);
        if (WAGRFeatureParseBool(raw, &value)) {
            if (outValue) *outValue = value;
            if (outSource) *outSource = WAGRFeatureStateSourceOriginal;
            return YES;
        }
    }

    NSUInteger stableID = WAGRFeatureResolvedABID(selectorName, fallbackStableID);
    if (WAGRFeatureNativeBool(stableID, &value)) {
        if (outValue) *outValue = value;
        if (outSource) *outSource = WAGRFeatureStateSourceNativeCache;
        return YES;
    }
    return NO;
}

BOOL WAGRFeatureSetBool(NSString *selectorName,
                        NSArray<NSDictionary *> *targets,
                        BOOL value) {
    if (!selectorName.length) return NO;
    NSArray *resolvedTargets = WAGRFeatureTargets(targets);
    NSArray *specs = [WAGRRuntimeValueAllOverrideSpecs() copy];

    for (NSDictionary *target in resolvedTargets) {
        NSString *wantedClass = [target[@"class"] isKindOfClass:NSString.class] ? target[@"class"] : @"";
        BOOL wantedMeta = [target[@"meta"] boolValue];
        for (NSDictionary *spec in specs) {
            NSString *specSelector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
            NSString *specClass = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
            if (![specSelector isEqualToString:selectorName] || ![specClass isEqualToString:wantedClass] ||
                [spec[@"meta"] boolValue] != wantedMeta) continue;
            NSString *type = [spec[@"type"] isKindOfClass:NSString.class] ? spec[@"type"] : nil;
            if (!type.length) continue;
            WAGRRuntimeValueSetOverride(wantedClass, selectorName, wantedMeta, type, @(value));
            (void)WAGRRuntimeValueInstallHook(wantedClass, selectorName, wantedMeta, type);
            return YES;
        }
    }

    for (NSDictionary *spec in specs) {
        NSString *specSelector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        if (![specSelector isEqualToString:selectorName] || !WAGRFeatureClassLooksLikeABProperties(className)) continue;
        BOOL meta = [spec[@"meta"] boolValue];
        NSString *type = [spec[@"type"] isKindOfClass:NSString.class] ? spec[@"type"] : nil;
        if (!type.length) continue;
        WAGRRuntimeValueSetOverride(className, selectorName, meta, type, @(value));
        (void)WAGRRuntimeValueInstallHook(className, selectorName, meta, type);
        return YES;
    }

    for (NSDictionary *target in resolvedTargets) {
        NSString *className = [target[@"class"] isKindOfClass:NSString.class] ? target[@"class"] : nil;
        BOOL meta = [target[@"meta"] boolValue];
        Class cls = className.length ? (NSClassFromString(className) ?: objc_getClass(className.UTF8String)) : Nil;
        NSString *type = WAGRFeatureMethodType(cls, selectorName, meta);
        if (!type.length) continue;
        WAGRRuntimeValueSetOverride(className, selectorName, meta, type, @(value));
        (void)WAGRRuntimeValueInstallHook(className, selectorName, meta, type);
        return WAGRRuntimeValueHasOverride(className, selectorName, meta);
    }
    return NO;
}

void WAGRFeatureClearBool(NSString *selectorName,
                          NSArray<NSDictionary *> *targets) {
    if (!selectorName.length) return;
    NSMutableSet<NSString *> *wantedClasses = [NSMutableSet set];
    for (NSDictionary *target in WAGRFeatureTargets(targets)) {
        NSString *className = [target[@"class"] isKindOfClass:NSString.class] ? target[@"class"] : nil;
        if (className.length) [wantedClasses addObject:className];
    }
    for (NSDictionary *spec in [WAGRRuntimeValueAllOverrideSpecs() copy]) {
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        if (![selector isEqualToString:selectorName]) continue;
        if (![wantedClasses containsObject:className] && !WAGRFeatureClassLooksLikeABProperties(className)) continue;
        WAGRRuntimeValueClearOverride(className, selectorName, [spec[@"meta"] boolValue]);
    }
}
