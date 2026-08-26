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
    if ([raw respondsToSelector:@selector(boolValue)] && ![raw isKindOfClass:NSString.class]) {
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
    @synchronized ([WAGRFeatureStateSource class]) {
        if (cached && [cachedFingerprint isEqualToString:snapshot.fingerprint ?: @""]) return cached;
        NSDictionary *document = WAGRABPropsNativeExportDocument(snapshot);
        NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class] ? document[@"entries"] : @[];
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *entry in entries) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : nil;
            NSNumber *code = [entry[@"code"] respondsToSelector:@selector(unsignedIntegerValue)]
                ? @([entry[@"code"] unsignedIntegerValue]) : nil;
            if (name.length && code.unsignedIntegerValue && !map[name]) map[name] = code;
        }
        cached = [map copy];
        cachedFingerprint = [snapshot.fingerprint copy] ?: @"";
        return cached;
    }
}

NSUInteger WAGRFeatureResolvedABID(NSString *selectorName, NSUInteger fallbackStableID) {
    NSNumber *code = selectorName.length ? WAGRFeatureNameToCode()[selectorName] : nil;
    return code.unsignedIntegerValue ?: fallbackStableID;
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
            if (![spec[@"selector"] isEqual:selectorName] ||
                ![spec[@"class"] isEqual:wantedClass] ||
                [spec[@"meta"] boolValue] != wantedMeta) continue;
            id value = WAGRRuntimeValueOverride(wantedClass, selectorName, wantedMeta);
            if (WAGRFeatureParseBool(value, outValue)) return YES;
        }
    }
    // Compatibility with an exact ABProperties implementation that differs from
    // the declared facade class. Do not accept an unrelated same-selector class.
    for (NSDictionary *spec in specs) {
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        if (![spec[@"selector"] isEqual:selectorName] ||
            ![className.lowercaseString containsString:@"abpropert"]) continue;
        BOOL meta = [spec[@"meta"] boolValue];
        id value = WAGRRuntimeValueOverride(className, selectorName, meta);
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
    NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();

    // If the ABProperties Browser already owns an exact selector override, update
    // that exact record instead of creating a parallel key.
    for (NSDictionary *target in resolvedTargets) {
        NSString *wantedClass = [target[@"class"] isKindOfClass:NSString.class] ? target[@"class"] : @"";
        BOOL wantedMeta = [target[@"meta"] boolValue];
        for (NSDictionary *spec in specs) {
            if (![spec[@"selector"] isEqual:selectorName] ||
                ![spec[@"class"] isEqual:wantedClass] ||
                [spec[@"meta"] boolValue] != wantedMeta) continue;
            NSString *type = [spec[@"type"] isKindOfClass:NSString.class] ? spec[@"type"] : nil;
            if (!type.length) continue;
            WAGRRuntimeValueSetOverride(wantedClass, selectorName, wantedMeta, type, @(value));
            (void)WAGRRuntimeValueInstallHook(wantedClass, selectorName, wantedMeta, type);
            return YES;
        }
    }
    for (NSDictionary *spec in specs) {
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        if (![spec[@"selector"] isEqual:selectorName] ||
            ![className.lowercaseString containsString:@"abpropert"]) continue;
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
    NSSet *wanted = [NSSet setWithArray:[WAGRFeatureTargets(targets) valueForKey:@"class"] ?: @[]];
    for (NSDictionary *spec in [WAGRRuntimeValueAllOverrideSpecs() copy]) {
        NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : @"";
        NSString *selector = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : @"";
        if (![selector isEqualToString:selectorName]) continue;
        if (![wanted containsObject:className] && ![className.lowercaseString containsString:@"abpropert"]) continue;
        WAGRRuntimeValueClearOverride(className, selectorName, [spec[@"meta"] boolValue]);
    }
}
