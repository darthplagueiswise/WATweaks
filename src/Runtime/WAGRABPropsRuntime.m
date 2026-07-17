// WAGRABPropsRuntime.m
// Metadata scanner and ABI-correct value reader for WhatsApp AB Properties.

#import "WAGRABPropsRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>

@implementation WAGRABPropEntry
@end

static id WAGRABCallNoArgObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;

    id value = nil;
    @try {
        value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value;
}

static BOOL WAGRABObjectLooksLikeProperties(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]) ?: @"";
    if ([name rangeOfString:@"ABPropert" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    return [object respondsToSelector:NSSelectorFromString(@"isMetaEmployeeOrInternalTester")] ||
           [object respondsToSelector:NSSelectorFromString(@"waios_mc_debug_ui_enabled")];
}

NSArray *WAGRABPropsResolveRuntimeObjects(id userContext) {
    NSMutableOrderedSet *objects = [NSMutableOrderedSet orderedSet];
    if (WAGRABObjectLooksLikeProperties(userContext)) [objects addObject:userContext];

    for (NSString *selectorName in @[
        @"abProperties",
        @"waABProperties",
        @"privateABProperties",
        @"serverProperties"
    ]) {
        id value = WAGRABCallNoArgObject(userContext, selectorName);
        if (WAGRABObjectLooksLikeProperties(value)) [objects addObject:value];
    }
    return objects.array ?: @[];
}

static const char *WAGRABSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static NSString *WAGRABTypeName(const char *rawType) {
    const char *type = WAGRABSkipQualifiers(rawType);
    if (!type || !type[0]) return nil;
    switch (type[0]) {
        case 'B': return @"BOOL";
        case 'c': return @"BOOL/char";
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

BOOL WAGRABPropEntryIsBoolean(WAGRABPropEntry *entry) {
    const char *type = WAGRABSkipQualifiers(entry.typeCode.UTF8String);
    return type && (type[0] == 'B' || type[0] == 'c');
}

static NSArray *WAGRABClassesToScan(NSArray *runtimeObjects) {
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];
    for (id object in runtimeObjects) {
        Class cls = [object class];
        while (cls && cls != NSObject.class) {
            NSString *name = NSStringFromClass(cls) ?: @"";
            if ([name rangeOfString:@"ABPropert" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [classes addObject:cls];
            }
            cls = class_getSuperclass(cls);
        }
    }

    for (NSString *name in @[
        @"WAABProperties",
        @"FOAWAABPropertiesImpl",
        @"WAFoundation.FOAWAABPropertiesImpl",
        @"WAABPropertiesPreChatd",
        @"_TtC24WAPrivateExperimentation19PrivateABProperties"
    ]) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (cls) [classes addObject:cls];
    }
    return classes.array ?: @[];
}

NSArray<WAGRABPropEntry *> *WAGRABPropsScan(NSArray *runtimeObjects) {
    NSMutableArray<WAGRABPropEntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (Class baseClass in WAGRABClassesToScan(runtimeObjects)) {
        for (NSUInteger meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(baseClass) : baseClass;
            if (!owner) continue;

            unsigned int count = 0;
            Method *methods = class_copyMethodList(owner, &count);
            if (!methods) continue;

            for (unsigned int index = 0; index < count; index++) {
                Method method = methods[index];
                if (!method || method_getNumberOfArguments(method) != 2) continue;

                NSString *selectorName = NSStringFromSelector(method_getName(method));
                if (!selectorName.length || [selectorName containsString:@":"]) continue;

                char returnType[64] = {0};
                method_getReturnType(method, returnType, sizeof(returnType));
                NSString *typeName = WAGRABTypeName(returnType);
                if (!typeName.length) continue;

                NSString *className = NSStringFromClass(baseClass) ?: @"";
                NSString *unique = [NSString stringWithFormat:@"%@|%@|%@",
                                    className,
                                    meta ? @"class" : @"instance",
                                    selectorName];
                if ([seen containsObject:unique]) continue;
                [seen addObject:unique];

                WAGRABPropEntry *entry = [WAGRABPropEntry new];
                entry.className = className;
                entry.selectorName = selectorName;
                entry.typeCode = [NSString stringWithUTF8String:returnType] ?: @"";
                entry.typeName = typeName;
                entry.classMethod = (BOOL)meta;
                [entries addObject:entry];
            }
            free(methods);
        }
    }

    return [entries sortedArrayUsingComparator:^NSComparisonResult(WAGRABPropEntry *left,
                                                                    WAGRABPropEntry *right) {
        NSComparisonResult result = [left.className localizedCaseInsensitiveCompare:right.className];
        return result != NSOrderedSame
            ? result
            : [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
    }];
}

static id WAGRABReceiverForEntry(WAGRABPropEntry *entry, NSArray *runtimeObjects) {
    if (!entry) return nil;
    if (entry.classMethod) {
        return NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    }
    SEL selector = NSSelectorFromString(entry.selectorName);
    for (id object in runtimeObjects) {
        if ([object respondsToSelector:selector]) return object;
    }
    return nil;
}

NSString *WAGRABPropsCurrentValue(WAGRABPropEntry *entry,
                                  NSArray *runtimeObjects,
                                  BOOL *boolValue,
                                  BOOL *boolKnown) {
    if (boolKnown) *boolKnown = NO;
    id receiver = WAGRABReceiverForEntry(entry, runtimeObjects);
    if (!receiver) return @"receiver indisponível";

    SEL selector = NSSelectorFromString(entry.selectorName);
    if (![receiver respondsToSelector:selector]) return @"selector indisponível";
    IMP implementation = [receiver methodForSelector:selector];
    if (!implementation) return @"IMP indisponível";

    const char *type = WAGRABSkipQualifiers(entry.typeCode.UTF8String);
    if (!type || !type[0]) return @"tipo desconhecido";

    @try {
        switch (type[0]) {
            case 'B':
            case 'c': {
                BOOL value = ((BOOL (*)(id, SEL))implementation)(receiver, selector);
                if (boolValue) *boolValue = value;
                if (boolKnown) *boolKnown = YES;
                return value ? @"YES" : @"NO";
            }
            case 'C': return [NSString stringWithFormat:@"%u", (unsigned int)((unsigned char (*)(id, SEL))implementation)(receiver, selector)];
            case 's': return [NSString stringWithFormat:@"%d", (int)((short (*)(id, SEL))implementation)(receiver, selector)];
            case 'S': return [NSString stringWithFormat:@"%u", (unsigned int)((unsigned short (*)(id, SEL))implementation)(receiver, selector)];
            case 'i': return [NSString stringWithFormat:@"%d", ((int (*)(id, SEL))implementation)(receiver, selector)];
            case 'I': return [NSString stringWithFormat:@"%u", ((unsigned int (*)(id, SEL))implementation)(receiver, selector)];
            case 'l': return [NSString stringWithFormat:@"%ld", ((long (*)(id, SEL))implementation)(receiver, selector)];
            case 'L': return [NSString stringWithFormat:@"%lu", ((unsigned long (*)(id, SEL))implementation)(receiver, selector)];
            case 'q': return [NSString stringWithFormat:@"%lld", ((long long (*)(id, SEL))implementation)(receiver, selector)];
            case 'Q': return [NSString stringWithFormat:@"%llu", ((unsigned long long (*)(id, SEL))implementation)(receiver, selector)];
            case 'f': return [NSString stringWithFormat:@"%.9g", ((float (*)(id, SEL))implementation)(receiver, selector)];
            case 'd': return [NSString stringWithFormat:@"%.17g", ((double (*)(id, SEL))implementation)(receiver, selector)];
            case '@': {
                id value = ((id (*)(id, SEL))implementation)(receiver, selector);
                if (!value) return @"nil";
                NSString *description = [value description] ?: @"(sem description)";
                if (description.length > 400) {
                    description = [[description substringToIndex:400] stringByAppendingString:@"…"];
                }
                return [NSString stringWithFormat:@"%@ · %@", NSStringFromClass([value class]), description];
            }
            default: return @"tipo não suportado";
        }
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"exception %@: %@",
                exception.name ?: @"?",
                exception.reason ?: @"?"];
    }
}
