#import "WAGRRuntimeValueStore.h"
#import "../WAPrefix.h"
#import <objc/runtime.h>
#include <string.h>

NSString * const kWAGRRuntimeValueOverridesKey = WA_PREF_RUNTIME_VALUE_OVERRIDES;

static NSString * const kWAGRValueClassKey = @"class";
static NSString * const kWAGRValueSelectorKey = @"selector";
static NSString * const kWAGRValueMetaKey = @"meta";
static NSString * const kWAGRValueTypeKey = @"type";
static NSString * const kWAGRValuePayloadKey = @"value";
static NSString * const kWAGRValueKindKey = @"kind";
static NSString * const kWAGRNestedKindKey = @"__watweak_kind";
static NSString * const kWAGRNestedValueKey = @"__watweak_value";

@interface WAGRRuntimeValueHookDescriptor : NSObject
@property(nonatomic, copy) NSString *uid;
@property(nonatomic, assign) SEL selector;
@property(nonatomic, assign) IMP original;
@property(nonatomic, assign) char typeCode;
@end
@implementation WAGRRuntimeValueHookDescriptor
@end

static NSMutableDictionary<NSString *, NSDictionary *> *gWAGRValueOverrides;
static NSMutableDictionary<NSString *, WAGRRuntimeValueHookDescriptor *> *gWAGRValueHooks;
static NSObject *gWAGRValueLock;
static dispatch_once_t gWAGRValueOnce;

static NSString *WAGRRuntimeValueNormalizedType(NSString *typeCode) {
    if (!typeCode.length) return @"";
    const char *cursor = typeCode.UTF8String;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor ? [NSString stringWithFormat:@"%c", *cursor] : @"";
}

static id WAGRRuntimeValueEncodeNested(id value);
static id WAGRRuntimeValueDecodeNested(id value);

static id WAGRRuntimeValueEncodeNested(id value) {
    if (!value || value == NSNull.null) {
        return @{ kWAGRNestedKindKey: @"nil" };
    }
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
        return value;
    }
    if ([value isKindOfClass:NSURL.class]) {
        return @{ kWAGRNestedKindKey: @"url",
                  kWAGRNestedValueKey: [(NSURL *)value absoluteString] ?: @"" };
    }
    if ([value isKindOfClass:NSData.class]) {
        return @{ kWAGRNestedKindKey: @"data",
                  kWAGRNestedValueKey: [(NSData *)value base64EncodedStringWithOptions:0] ?: @"" };
    }
    if ([value isKindOfClass:NSDate.class]) {
        return @{ kWAGRNestedKindKey: @"date",
                  kWAGRNestedValueKey: @([(NSDate *)value timeIntervalSince1970]) };
    }
    if ([value isKindOfClass:NSSet.class]) {
        NSMutableArray *encoded = [NSMutableArray array];
        for (id item in [(NSSet *)value allObjects]) {
            [encoded addObject:WAGRRuntimeValueEncodeNested(item) ?: @{ kWAGRNestedKindKey: @"nil" }];
        }
        return @{ kWAGRNestedKindKey: @"set", kWAGRNestedValueKey: encoded };
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *encoded = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) {
            [encoded addObject:WAGRRuntimeValueEncodeNested(item) ?: @{ kWAGRNestedKindKey: @"nil" }];
        }
        return encoded;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *encoded = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            (void)stop;
            NSString *stringKey = [key isKindOfClass:NSString.class] ? key : [key description];
            if (!stringKey.length) return;
            encoded[stringKey] = WAGRRuntimeValueEncodeNested(object) ?: @{ kWAGRNestedKindKey: @"nil" };
        }];
        return encoded;
    }
    return nil;
}

static id WAGRRuntimeValueDecodeNested(id value) {
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *decoded = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) {
            id object = WAGRRuntimeValueDecodeNested(item);
            [decoded addObject:object ?: NSNull.null];
        }
        return decoded;
    }
    if (![value isKindOfClass:NSDictionary.class]) return value;

    NSString *kind = [(NSDictionary *)value objectForKey:kWAGRNestedKindKey];
    id payload = [(NSDictionary *)value objectForKey:kWAGRNestedValueKey];
    if ([kind isEqualToString:@"nil"]) return nil;
    if ([kind isEqualToString:@"url"]) return [NSURL URLWithString:[payload description] ?: @""];
    if ([kind isEqualToString:@"data"]) return [[NSData alloc] initWithBase64EncodedString:[payload description] ?: @"" options:0];
    if ([kind isEqualToString:@"date"]) return [NSDate dateWithTimeIntervalSince1970:[payload doubleValue]];
    if ([kind isEqualToString:@"set"]) {
        id decoded = WAGRRuntimeValueDecodeNested(payload);
        return [decoded isKindOfClass:NSArray.class] ? [NSSet setWithArray:decoded] : [NSSet set];
    }

    NSMutableDictionary *decoded = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
        (void)stop;
        id decodedObject = WAGRRuntimeValueDecodeNested(object);
        decoded[key] = decodedObject ?: NSNull.null;
    }];
    return decoded;
}

static NSDictionary *WAGRRuntimeValueEncodedObjectSpec(id value) {
    if (!value || value == NSNull.null) {
        return @{ kWAGRValueKindKey: @"nil", kWAGRValuePayloadKey: @"" };
    }
    id encoded = WAGRRuntimeValueEncodeNested(value);
    if (!encoded) return nil;

    NSString *kind = @"foundation";
    if ([value isKindOfClass:NSString.class]) kind = @"string";
    else if ([value isKindOfClass:NSNumber.class]) kind = @"number";
    else if ([value isKindOfClass:NSArray.class]) kind = @"array";
    else if ([value isKindOfClass:NSDictionary.class]) kind = @"dictionary";
    else if ([value isKindOfClass:NSSet.class]) kind = @"set";
    else if ([value isKindOfClass:NSURL.class]) kind = @"url";
    else if ([value isKindOfClass:NSData.class]) kind = @"data";
    else if ([value isKindOfClass:NSDate.class]) kind = @"date";

    return @{ kWAGRValueKindKey: kind, kWAGRValuePayloadKey: encoded };
}

static id WAGRRuntimeValueDecodeSpec(NSDictionary *spec) {
    if (![spec isKindOfClass:NSDictionary.class]) return nil;
    NSString *type = spec[kWAGRValueTypeKey];
    id payload = spec[kWAGRValuePayloadKey];
    if (![type isEqualToString:@"@"]) return payload;
    NSString *kind = spec[kWAGRValueKindKey];
    if ([kind isEqualToString:@"nil"]) return nil;
    return WAGRRuntimeValueDecodeNested(payload);
}

static void WAGRRuntimeValueEnsureStorage(void) {
    dispatch_once(&gWAGRValueOnce, ^{
        gWAGRValueLock = [NSObject new];
        gWAGRValueHooks = [NSMutableDictionary dictionary];
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWAGRRuntimeValueOverridesKey];
        gWAGRValueOverrides = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    });
}

NSString *WAGRRuntimeValueUID(NSString *className,
                               NSString *selectorName,
                               BOOL isClassMethod) {
    if (!className.length || !selectorName.length) return @"";
    return [NSString stringWithFormat:@"%@|%@|%@",
            className,
            isClassMethod ? @"class" : @"instance",
            selectorName];
}

NSString *WAGRRuntimeValueTypeName(NSString *typeCode) {
    NSString *type = WAGRRuntimeValueNormalizedType(typeCode);
    if (!type.length) return nil;
    switch ([type characterAtIndex:0]) {
        case 'B': return @"BOOL";
        case 'c': return @"char/BOOL";
        case 'C': return @"uint8";
        case 's': return @"int16";
        case 'S': return @"uint16";
        case 'i': return @"int32";
        case 'I': return @"uint32";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"int64";
        case 'Q': return @"uint64";
        case 'f': return @"float";
        case 'd': return @"double";
        case '@': return @"object";
        default: return nil;
    }
}

BOOL WAGRRuntimeValueTypeIsSupported(NSString *typeCode) {
    return WAGRRuntimeValueTypeName(typeCode) != nil;
}
BOOL WAGRRuntimeValueTypeIsBoolean(NSString *typeCode) {
    NSString *type = WAGRRuntimeValueNormalizedType(typeCode);
    return [type isEqualToString:@"B"] || [type isEqualToString:@"c"];
}
BOOL WAGRRuntimeValueTypeIsSignedInteger(NSString *typeCode) {
    NSString *type = WAGRRuntimeValueNormalizedType(typeCode);
    return [@[@"s", @"i", @"l", @"q"] containsObject:type];
}
BOOL WAGRRuntimeValueTypeIsUnsignedInteger(NSString *typeCode) {
    NSString *type = WAGRRuntimeValueNormalizedType(typeCode);
    return [@[@"C", @"S", @"I", @"L", @"Q"] containsObject:type];
}
BOOL WAGRRuntimeValueTypeIsFloatingPoint(NSString *typeCode) {
    NSString *type = WAGRRuntimeValueNormalizedType(typeCode);
    return [type isEqualToString:@"f"] || [type isEqualToString:@"d"];
}
BOOL WAGRRuntimeValueTypeIsObject(NSString *typeCode) {
    return [WAGRRuntimeValueNormalizedType(typeCode) isEqualToString:@"@"]; 
}

static NSDictionary *WAGRRuntimeValueSpec(NSString *className,
                                           NSString *selectorName,
                                           BOOL isClassMethod) {
    WAGRRuntimeValueEnsureStorage();
    NSString *uid = WAGRRuntimeValueUID(className, selectorName, isClassMethod);
    if (!uid.length) return nil;
    @synchronized (gWAGRValueLock) {
        return gWAGRValueOverrides[uid];
    }
}

BOOL WAGRRuntimeValueHasOverride(NSString *className,
                                 NSString *selectorName,
                                 BOOL isClassMethod) {
    return WAGRRuntimeValueSpec(className, selectorName, isClassMethod) != nil;
}

id WAGRRuntimeValueOverride(NSString *className,
                            NSString *selectorName,
                            BOOL isClassMethod) {
    return WAGRRuntimeValueDecodeSpec(WAGRRuntimeValueSpec(className, selectorName, isClassMethod));
}

static void WAGRRuntimeValuePersistLocked(void) {
    [NSUserDefaults.standardUserDefaults setObject:gWAGRValueOverrides
                                           forKey:kWAGRRuntimeValueOverridesKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

void WAGRRuntimeValueSetOverride(NSString *className,
                                 NSString *selectorName,
                                 BOOL isClassMethod,
                                 NSString *typeCode,
                                 id value) {
    NSString *uid = WAGRRuntimeValueUID(className, selectorName, isClassMethod);
    NSString *normalized = WAGRRuntimeValueNormalizedType(typeCode);
    if (!uid.length || !normalized.length) return;

    NSMutableDictionary *spec = [@{
        kWAGRValueClassKey: className,
        kWAGRValueSelectorKey: selectorName,
        kWAGRValueMetaKey: @(isClassMethod),
        kWAGRValueTypeKey: normalized
    } mutableCopy];

    if ([normalized isEqualToString:@"@"]) {
        NSDictionary *encoded = WAGRRuntimeValueEncodedObjectSpec(value);
        if (!encoded) return;
        [spec addEntriesFromDictionary:encoded];
    } else {
        if (![value isKindOfClass:NSNumber.class]) return;
        spec[kWAGRValuePayloadKey] = value;
    }

    WAGRRuntimeValueEnsureStorage();
    @synchronized (gWAGRValueLock) {
        gWAGRValueOverrides[uid] = spec;
        WAGRRuntimeValuePersistLocked();
    }
}

void WAGRRuntimeValueClearOverride(NSString *className,
                                   NSString *selectorName,
                                   BOOL isClassMethod) {
    NSString *uid = WAGRRuntimeValueUID(className, selectorName, isClassMethod);
    if (!uid.length) return;
    WAGRRuntimeValueEnsureStorage();
    @synchronized (gWAGRValueLock) {
        [gWAGRValueOverrides removeObjectForKey:uid];
        WAGRRuntimeValuePersistLocked();
    }
}

NSArray<NSDictionary<NSString *, id> *> *WAGRRuntimeValueAllOverrideSpecs(void) {
    WAGRRuntimeValueEnsureStorage();
    @synchronized (gWAGRValueLock) {
        return [gWAGRValueOverrides.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSString *leftName = [NSString stringWithFormat:@"%@ %@", left[kWAGRValueClassKey] ?: @"", left[kWAGRValueSelectorKey] ?: @""];
            NSString *rightName = [NSString stringWithFormat:@"%@ %@", right[kWAGRValueClassKey] ?: @"", right[kWAGRValueSelectorKey] ?: @""];
            return [leftName localizedCaseInsensitiveCompare:rightName];
        }];
    }
}

static id WAGRRuntimeValueForcedValue(WAGRRuntimeValueHookDescriptor *descriptor,
                                      BOOL *hasOverride) {
    if (hasOverride) *hasOverride = NO;
    if (!descriptor.uid.length) return nil;
    WAGRRuntimeValueEnsureStorage();
    @synchronized (gWAGRValueLock) {
        NSDictionary *spec = gWAGRValueOverrides[descriptor.uid];
        if (!spec) return nil;
        if (hasOverride) *hasOverride = YES;
        return WAGRRuntimeValueDecodeSpec(spec);
    }
}

static IMP WAGRRuntimeValueReplacement(WAGRRuntimeValueHookDescriptor *descriptor) {
    switch (descriptor.typeCode) {
        case 'B': return imp_implementationWithBlock(^BOOL(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced boolValue];
            return descriptor.original ? ((BOOL (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : NO;
        });
        case 'c': return imp_implementationWithBlock(^signed char(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return (signed char)[forced charValue];
            return descriptor.original ? ((signed char (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'C': return imp_implementationWithBlock(^unsigned char(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return (unsigned char)[forced unsignedCharValue];
            return descriptor.original ? ((unsigned char (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 's': return imp_implementationWithBlock(^short(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return (short)[forced shortValue];
            return descriptor.original ? ((short (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'S': return imp_implementationWithBlock(^unsigned short(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return (unsigned short)[forced unsignedShortValue];
            return descriptor.original ? ((unsigned short (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'i': return imp_implementationWithBlock(^int(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced intValue];
            return descriptor.original ? ((int (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'I': return imp_implementationWithBlock(^unsigned int(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced unsignedIntValue];
            return descriptor.original ? ((unsigned int (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'l': return imp_implementationWithBlock(^long(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced longValue];
            return descriptor.original ? ((long (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'L': return imp_implementationWithBlock(^unsigned long(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced unsignedLongValue];
            return descriptor.original ? ((unsigned long (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'q': return imp_implementationWithBlock(^long long(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced longLongValue];
            return descriptor.original ? ((long long (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'Q': return imp_implementationWithBlock(^unsigned long long(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced unsignedLongLongValue];
            return descriptor.original ? ((unsigned long long (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0;
        });
        case 'f': return imp_implementationWithBlock(^float(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced floatValue];
            return descriptor.original ? ((float (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0.0f;
        });
        case 'd': return imp_implementationWithBlock(^double(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return [forced doubleValue];
            return descriptor.original ? ((double (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : 0.0;
        });
        case '@': return imp_implementationWithBlock(^id(id receiver) {
            BOOL has = NO; id forced = WAGRRuntimeValueForcedValue(descriptor, &has);
            if (has) return forced;
            return descriptor.original ? ((id (*)(id, SEL))descriptor.original)(receiver, descriptor.selector) : nil;
        });
        default: return NULL;
    }
}

static Method WAGRRuntimeValueOwnMethod(Class target, SEL selector) {
    if (!target || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

BOOL WAGRRuntimeValueInstallHook(NSString *className,
                                 NSString *selectorName,
                                 BOOL isClassMethod,
                                 NSString *typeCode) {
    NSString *uid = WAGRRuntimeValueUID(className, selectorName, isClassMethod);
    NSString *normalized = WAGRRuntimeValueNormalizedType(typeCode);
    if (!uid.length || !WAGRRuntimeValueTypeIsSupported(normalized)) return NO;
    WAGRRuntimeValueEnsureStorage();
    @synchronized (gWAGRValueLock) {
        if (gWAGRValueHooks[uid]) return YES;
    }

    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Class target = isClassMethod ? object_getClass(cls) : cls;
    if (!target) return NO;

    // Work against the method table directly. This is both more deterministic
    // for sideloaded iOS 26/27 processes and avoids inline text patching. If the
    // selector is inherited, class_addMethod creates a local override while the
    // descriptor keeps the inherited IMP as the exact original fallback.
    Method resolved = class_getInstanceMethod(target, selector);
    if (!resolved || method_getNumberOfArguments(resolved) != 2) return NO;

    char actual[64] = {0};
    method_getReturnType(resolved, actual, sizeof(actual));
    NSString *actualType = WAGRRuntimeValueNormalizedType([NSString stringWithUTF8String:actual]);
    if (![actualType isEqualToString:normalized]) return NO;

    WAGRRuntimeValueHookDescriptor *descriptor = [WAGRRuntimeValueHookDescriptor new];
    descriptor.uid = uid;
    descriptor.selector = selector;
    descriptor.typeCode = (char)[normalized characterAtIndex:0];
    descriptor.original = method_getImplementation(resolved);
    if (!descriptor.original) return NO;

    IMP replacement = WAGRRuntimeValueReplacement(descriptor);
    if (!replacement) return NO;

    Method own = WAGRRuntimeValueOwnMethod(target, selector);
    if (own) {
        IMP previous = method_setImplementation(own, replacement);
        if (!previous || previous == replacement) return NO;
        descriptor.original = previous;
    } else {
        const char *types = method_getTypeEncoding(resolved);
        if (!types || !class_addMethod(target, selector, replacement, types)) return NO;
    }

    @synchronized (gWAGRValueLock) {
        gWAGRValueHooks[uid] = descriptor;
    }
    return YES;
}

NSUInteger WAGRRuntimeValueReinstallPersistedHooks(void) {
    NSUInteger installed = 0;
    for (NSDictionary *spec in WAGRRuntimeValueAllOverrideSpecs()) {
        NSString *className = spec[kWAGRValueClassKey];
        NSString *selectorName = spec[kWAGRValueSelectorKey];
        NSString *typeCode = spec[kWAGRValueTypeKey];
        BOOL meta = [spec[kWAGRValueMetaKey] boolValue];
        if (WAGRRuntimeValueInstallHook(className, selectorName, meta, typeCode)) installed++;
    }
    return installed;
}

static id WAGRRuntimeValueReceiver(NSString *className,
                                   NSString *selectorName,
                                   BOOL isClassMethod,
                                   id instance) {
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    if (!cls) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (isClassMethod) return [cls respondsToSelector:selector] ? cls : nil;
    if (instance && [instance respondsToSelector:selector]) return instance;
    return nil;
}

NSString *WAGRRuntimeValueRead(NSString *className,
                               NSString *selectorName,
                               BOOL isClassMethod,
                               id instance,
                               id *rawValue) {
    if (rawValue) *rawValue = nil;
    id receiver = WAGRRuntimeValueReceiver(className, selectorName, isClassMethod, instance);
    if (!receiver) return @"receiver indisponível";
    SEL selector = NSSelectorFromString(selectorName);
    Method method = isClassMethod
        ? class_getClassMethod((Class)receiver, selector)
        : class_getInstanceMethod([receiver class], selector);
    if (!method) return @"método indisponível";
    char rawType[64] = {0};
    method_getReturnType(method, rawType, sizeof(rawType));
    NSString *type = WAGRRuntimeValueNormalizedType([NSString stringWithUTF8String:rawType]);
    IMP imp = [receiver methodForSelector:selector];
    if (!imp || !type.length) return @"IMP/tipo indisponível";

    @try {
        switch ([type characterAtIndex:0]) {
            case 'B': { BOOL value = ((BOOL (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return value ? @"YES" : @"NO"; }
            case 'c': { signed char value = ((signed char (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%d", (int)value]; }
            case 'C': { unsigned char value = ((unsigned char (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%u", (unsigned int)value]; }
            case 's': { short value = ((short (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%d", (int)value]; }
            case 'S': { unsigned short value = ((unsigned short (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%u", (unsigned int)value]; }
            case 'i': { int value = ((int (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%d", value]; }
            case 'I': { unsigned int value = ((unsigned int (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%u", value]; }
            case 'l': { long value = ((long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%ld", value]; }
            case 'L': { unsigned long value = ((unsigned long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%lu", value]; }
            case 'q': { long long value = ((long long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%lld", value]; }
            case 'Q': { unsigned long long value = ((unsigned long long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%llu", value]; }
            case 'f': { float value = ((float (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%.9g", value]; }
            case 'd': { double value = ((double (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(value); return [NSString stringWithFormat:@"%.17g", value]; }
            case '@': {
                id value = ((id (*)(id, SEL))imp)(receiver, selector);
                if (rawValue) *rawValue = value;
                if (!value) return @"nil";
                NSString *description = [value description] ?: @"(sem description)";
                if (description.length > 500) description = [[description substringToIndex:500] stringByAppendingString:@"…"];
                return [NSString stringWithFormat:@"%@ · %@", NSStringFromClass([value class]), description];
            }
            default: return @"tipo não suportado";
        }
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"exception %@: %@", exception.name ?: @"?", exception.reason ?: @"?"];
    }
}

__attribute__((constructor))
static void WAGRRuntimeValueStoreCtor(void) {
    WAGRRuntimeValueEnsureStorage();
    if (WAGRRuntimeValueAllOverrideSpecs().count == 0) return;
    (void)WAGRRuntimeValueReinstallPersistedHooks();
}
