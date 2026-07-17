#import "WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#import <substrate.h>
#include <string.h>

NSString * const kWAGRRuntimeValueOverridesKey = @"watweak_runtime_value_overrides_v1";

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

static void WAGRRuntimeValueEnsureStorage(void) {
    dispatch_once(&gWAGRValueOnce, ^{
        gWAGRValueLock = [NSObject new];
        gWAGRValueHooks = [NSMutableDictionary dictionary];
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWAGRRuntimeValueOverridesKey];
        gWAGRValueOverrides = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    });
}

static NSString *WAGRRuntimeValueNormalizedType(NSString *typeCode) {
    if (!typeCode.length) return @"";
    const char *p = typeCode.UTF8String;
    while (*p && strchr("rnNoORV", *p)) p++;
    return *p ? [NSString stringWithFormat:@"%c", *p] : @"";
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
    NSString *t = WAGRRuntimeValueNormalizedType(typeCode);
    if (!t.length) return nil;
    switch ([t characterAtIndex:0]) {
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
    NSString *t = WAGRRuntimeValueNormalizedType(typeCode);
    return [t isEqualToString:@"B"] || [t isEqualToString:@"c"];
}
BOOL WAGRRuntimeValueTypeIsSignedInteger(NSString *typeCode) {
    NSString *t = WAGRRuntimeValueNormalizedType(typeCode);
    return [@[@"s", @"i", @"l", @"q"] containsObject:t];
}
BOOL WAGRRuntimeValueTypeIsUnsignedInteger(NSString *typeCode) {
    NSString *t = WAGRRuntimeValueNormalizedType(typeCode);
    return [@[@"C", @"S", @"I", @"L", @"Q"] containsObject:t];
}
BOOL WAGRRuntimeValueTypeIsFloatingPoint(NSString *typeCode) {
    NSString *t = WAGRRuntimeValueNormalizedType(typeCode);
    return [t isEqualToString:@"f"] || [t isEqualToString:@"d"];
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
    return WAGRRuntimeValueSpec(className, selectorName, isClassMethod)[@"value"];
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
    if (!uid.length || !normalized.length || !value) return;
    WAGRRuntimeValueEnsureStorage();
    NSDictionary *spec = @{
        @"class": className,
        @"selector": selectorName,
        @"meta": @(isClassMethod),
        @"type": normalized,
        @"value": value
    };
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
            NSString *a = [NSString stringWithFormat:@"%@ %@", left[@"class"] ?: @"", left[@"selector"] ?: @""];
            NSString *b = [NSString stringWithFormat:@"%@ %@", right[@"class"] ?: @"", right[@"selector"] ?: @""];
            return [a localizedCaseInsensitiveCompare:b];
        }];
    }
}

static id WAGRRuntimeValueForcedValue(WAGRRuntimeValueHookDescriptor *descriptor) {
    if (!descriptor.uid.length) return nil;
    WAGRRuntimeValueEnsureStorage();
    @synchronized (gWAGRValueLock) {
        return gWAGRValueOverrides[descriptor.uid][@"value"];
    }
}

static IMP WAGRRuntimeValueReplacement(WAGRRuntimeValueHookDescriptor *d) {
    switch (d.typeCode) {
        case 'B': return imp_implementationWithBlock(^BOOL(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced boolValue];
            return d.original ? ((BOOL (*)(id, SEL))d.original)(receiver, d.selector) : NO;
        });
        case 'c': return imp_implementationWithBlock(^signed char(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return (signed char)[forced charValue];
            return d.original ? ((signed char (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'C': return imp_implementationWithBlock(^unsigned char(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return (unsigned char)[forced unsignedCharValue];
            return d.original ? ((unsigned char (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 's': return imp_implementationWithBlock(^short(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return (short)[forced shortValue];
            return d.original ? ((short (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'S': return imp_implementationWithBlock(^unsigned short(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return (unsigned short)[forced unsignedShortValue];
            return d.original ? ((unsigned short (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'i': return imp_implementationWithBlock(^int(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced intValue];
            return d.original ? ((int (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'I': return imp_implementationWithBlock(^unsigned int(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced unsignedIntValue];
            return d.original ? ((unsigned int (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'l': return imp_implementationWithBlock(^long(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced longValue];
            return d.original ? ((long (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'L': return imp_implementationWithBlock(^unsigned long(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced unsignedLongValue];
            return d.original ? ((unsigned long (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'q': return imp_implementationWithBlock(^long long(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced longLongValue];
            return d.original ? ((long long (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'Q': return imp_implementationWithBlock(^unsigned long long(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced unsignedLongLongValue];
            return d.original ? ((unsigned long long (*)(id, SEL))d.original)(receiver, d.selector) : 0;
        });
        case 'f': return imp_implementationWithBlock(^float(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced floatValue];
            return d.original ? ((float (*)(id, SEL))d.original)(receiver, d.selector) : 0.0f;
        });
        case 'd': return imp_implementationWithBlock(^double(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return [forced doubleValue];
            return d.original ? ((double (*)(id, SEL))d.original)(receiver, d.selector) : 0.0;
        });
        case '@': return imp_implementationWithBlock(^id(id receiver) {
            id forced = WAGRRuntimeValueForcedValue(d);
            if (forced) return forced == NSNull.null ? nil : forced;
            return d.original ? ((id (*)(id, SEL))d.original)(receiver, d.selector) : nil;
        });
        default: return NULL;
    }
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
    Method method = isClassMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char actual[64] = {0};
    method_getReturnType(method, actual, sizeof(actual));
    NSString *actualType = WAGRRuntimeValueNormalizedType([NSString stringWithUTF8String:actual]);
    if (![actualType isEqualToString:normalized]) return NO;

    WAGRRuntimeValueHookDescriptor *descriptor = [WAGRRuntimeValueHookDescriptor new];
    descriptor.uid = uid;
    descriptor.selector = selector;
    descriptor.typeCode = (char)[normalized characterAtIndex:0];
    IMP replacement = WAGRRuntimeValueReplacement(descriptor);
    if (!replacement) return NO;

    Class target = isClassMethod ? object_getClass(cls) : cls;
    IMP original = NULL;
    MSHookMessageEx(target, selector, replacement, &original);
    if (!original || original == replacement) return NO;
    descriptor.original = original;
    @synchronized (gWAGRValueLock) {
        gWAGRValueHooks[uid] = descriptor;
    }
    return YES;
}

NSUInteger WAGRRuntimeValueReinstallPersistedHooks(void) {
    NSUInteger installed = 0;
    for (NSDictionary *spec in WAGRRuntimeValueAllOverrideSpecs()) {
        NSString *className = spec[@"class"];
        NSString *selectorName = spec[@"selector"];
        NSString *typeCode = spec[@"type"];
        BOOL meta = [spec[@"meta"] boolValue];
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
            case 'B': { BOOL v = ((BOOL (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return v ? @"YES" : @"NO"; }
            case 'c': { signed char v = ((signed char (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%d", (int)v]; }
            case 'C': { unsigned char v = ((unsigned char (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%u", (unsigned int)v]; }
            case 's': { short v = ((short (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%d", (int)v]; }
            case 'S': { unsigned short v = ((unsigned short (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%u", (unsigned int)v]; }
            case 'i': { int v = ((int (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%d", v]; }
            case 'I': { unsigned int v = ((unsigned int (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%u", v]; }
            case 'l': { long v = ((long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%ld", v]; }
            case 'L': { unsigned long v = ((unsigned long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%lu", v]; }
            case 'q': { long long v = ((long long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%lld", v]; }
            case 'Q': { unsigned long long v = ((unsigned long long (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%llu", v]; }
            case 'f': { float v = ((float (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%.9g", v]; }
            case 'd': { double v = ((double (*)(id, SEL))imp)(receiver, selector); if (rawValue) *rawValue = @(v); return [NSString stringWithFormat:@"%.17g", v]; }
            case '@': {
                id v = ((id (*)(id, SEL))imp)(receiver, selector);
                if (rawValue) *rawValue = v;
                if (!v) return @"nil";
                NSString *description = [v description] ?: @"(sem description)";
                if (description.length > 500) description = [[description substringToIndex:500] stringByAppendingString:@"…"];
                return [NSString stringWithFormat:@"%@ · %@", NSStringFromClass([v class]), description];
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
