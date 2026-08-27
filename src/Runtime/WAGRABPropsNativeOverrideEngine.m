#import "WAGRABPropsNativeOverrideEngine.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRMobileConfigRuntimeResolver.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static NSString * const kWAGRABNativeErrorDomain = @"WATweaks.ABPropsNativeOverride";

static const char *WAGRABNativeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABNativeWordType(const char *type) {
    switch (WAGRABNativeSkipQualifiers(type)[0]) {
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
            return YES;
        default:
            return NO;
    }
}

static BOOL WAGRABNativeWordToWordMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char result[64] = {0};
    char argument[64] = {0};
    method_getReturnType(method, result, sizeof(result));
    method_getArgumentType(method, 2, argument, sizeof(argument));
    return WAGRABNativeWordType(result) && WAGRABNativeWordType(argument);
}

static uint64_t WAGRABNativeParseStableID(NSString *stableID) {
    if (![stableID isKindOfClass:NSString.class] || !stableID.length) return 0;
    const char *bytes = stableID.UTF8String;
    if (!bytes || !*bytes) return 0;
    char *end = NULL;
    unsigned long long value = strtoull(bytes, &end, 10);
    if (!value || end == bytes || (end && *end != '\0')) return 0;
    return (uint64_t)value;
}

static NSError *WAGRABNativeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kWAGRABNativeErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey : message ?: @"ABProps native override error"}];
}

static uint64_t WAGRABNativeSpecifier(uint64_t waStableID) {
    Class cls = NSClassFromString(@"WAMCEvaluation") ?: objc_getClass("WAMCEvaluation");
    SEL selector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!cls || !WAGRABNativeWordToWordMethod(method)) return 0;
    @try {
        return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)cls, selector, waStableID);
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static uint64_t WAGRABNativeExternalStableID(id manager, uint64_t specifier) {
    if (!manager || !specifier) return 0;
    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!WAGRABNativeWordToWordMethod(method)) return 0;
    @try {
        return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static NSDictionary *WAGRABNativeReadOverrideDocument(id userContext) {
    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    if (!path.length) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSString *WAGRABNativeStablePrefix(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return nil;
    NSString *prefix = [[key componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return nil;
    return [[prefix stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            length] ? prefix : nil;
}

static NSInteger WAGRABNativeRowIndex(NSString *row) {
    if (![row isKindOfClass:NSString.class]) return NSNotFound;
    NSString *prefix = [[row componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return NSNotFound;
    NSCharacterSet *bad = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    if ([prefix rangeOfCharacterFromSet:bad].location != NSNotFound) return NSNotFound;
    return prefix.integerValue;
}

NSDictionary<NSString *, id> *WAGRABPropsNativeOverrideMapping(NSString *waStableID,
                                                                id userContext,
                                                                NSString **outDiagnostic) {
    uint64_t waID = WAGRABNativeParseStableID(waStableID);
    if (!waID) {
        if (outDiagnostic) *outDiagnostic = @"WA stable ID inválido.";
        return nil;
    }

    uint64_t specifier = WAGRABNativeSpecifier(waID);
    if (!specifier || (specifier & (1ULL << 62))) {
        if (outDiagnostic) *outDiagnostic = @"WAMCEvaluation não retornou paramSpecifier válido para este ABProp.";
        return nil;
    }

    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    if (!manager) {
        if (outDiagnostic) *outDiagnostic = @"FBMobileConfigUserSessionContextManager exato não resolvido.";
        return nil;
    }

    uint64_t externalID = WAGRABNativeExternalStableID(manager, specifier);
    if (!externalID) {
        if (outDiagnostic) *outDiagnostic = @"UserSession não resolveu external config stable ID para este paramSpecifier.";
        return nil;
    }

    uint16_t parameterIndex = (uint16_t)((specifier >> 16) & 0xFFFF);
    uint8_t nativeType = (uint8_t)((specifier >> 48) & 0x3F);
    NSString *fullName = WAGRMobileConfigRuntimeNameForSpecifier(specifier);
    NSString *configName = nil;
    NSString *parameterName = nil;
    WAGRMobileConfigRuntimeSplitName(fullName, &configName, &parameterName);

    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    NSMutableDictionary *result = [@{
        @"wa_stable_id" : @(waID),
        @"param_specifier" : @(specifier),
        @"param_specifier_hex" : [NSString stringWithFormat:@"0x%016llx", specifier],
        @"external_config_stable_id" : @(externalID),
        @"parameter_index" : @(parameterIndex),
        @"native_type" : @(nativeType),
        @"manager_class" : NSStringFromClass([manager class]) ?: @"?",
        @"overrides_path" : path ?: @"",
    } mutableCopy];
    if (configName.length) result[@"config_name"] = configName;
    if (parameterName.length) result[@"parameter_name"] = parameterName;

    if (outDiagnostic) {
        *outDiagnostic = [NSString stringWithFormat:
            @"AB %@ -> specifier 0x%016llx -> external MC %llu / param %u (%@.%@)",
            waStableID, specifier, externalID, parameterIndex,
            configName ?: @"?", parameterName ?: @"?"];
    }
    return result;
}

static NSString *WAGRABNativeRowForMapping(NSDictionary *mapping, id userContext) {
    uint64_t externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
    NSInteger parameterIndex = [mapping[@"parameter_index"] integerValue];
    if (!externalID || parameterIndex < 0) return nil;
    NSString *wanted = [NSString stringWithFormat:@"%llu", externalID];
    NSDictionary *document = WAGRABNativeReadOverrideDocument(userContext);
    for (NSString *key in document) {
        if (![WAGRABNativeStablePrefix(key) isEqualToString:wanted]) continue;
        NSArray *rows = [document[key] isKindOfClass:NSArray.class] ? document[key] : @[];
        for (NSString *row in rows) {
            if (WAGRABNativeRowIndex(row) == parameterIndex) return row;
        }
    }
    return nil;
}

NSString *WAGRABPropsNativeOverrideRow(NSString *waStableID,
                                        id userContext,
                                        NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext,
                                                              &mappingDiagnostic);
    if (!mapping) {
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return nil;
    }
    NSString *row = WAGRABNativeRowForMapping(mapping, userContext);
    if (outDiagnostic) {
        *outDiagnostic = row.length
            ? [NSString stringWithFormat:@"%@; native row=%@", mappingDiagnostic ?: @"", row]
            : [NSString stringWithFormat:@"%@; native row=none", mappingDiagnostic ?: @""];
    }
    return row;
}

static NSString *WAGRABNativeValueString(id value, uint8_t nativeType) {
    if (!value || value == NSNull.null) return nil;
    switch (nativeType) {
        case 1:
            return [value respondsToSelector:@selector(boolValue)] && [value boolValue]
                ? @"true" : @"false";
        case 2:
            if (![value respondsToSelector:@selector(longLongValue)]) return nil;
            return [NSString stringWithFormat:@"%lld", [value longLongValue]];
        case 3: {
            if ([value isKindOfClass:NSString.class]) return value;
            if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
                if (![NSJSONSerialization isValidJSONObject:value]) return nil;
                NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            }
            return [value description];
        }
        case 4:
            if (![value respondsToSelector:@selector(doubleValue)]) return nil;
            return [NSString stringWithFormat:@"%.17g", [value doubleValue]];
        default:
            return nil;
    }
}

BOOL WAGRABPropsNativeSetOverride(NSString *waStableID,
                                  id value,
                                  id userContext,
                                  NSError **outError,
                                  NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext,
                                                              &mappingDiagnostic);
    if (!mapping) {
        if (outError) *outError = WAGRABNativeError(1, mappingDiagnostic);
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return NO;
    }

    uint8_t nativeType = (uint8_t)[mapping[@"native_type"] unsignedIntegerValue];
    NSString *valueString = WAGRABNativeValueString(value, nativeType);
    if (!valueString) {
        NSString *message = [NSString stringWithFormat:
            @"Valor incompatível com native_type=%u do WAMCEvaluation.", nativeType];
        if (outError) *outError = WAGRABNativeError(2, message);
        if (outDiagnostic) *outDiagnostic = message;
        return NO;
    }

    unsigned long long externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
    unsigned int parameterIndex = [mapping[@"parameter_index"] unsignedIntValue];
    NSString *configName = [mapping[@"config_name"] isKindOfClass:NSString.class]
        ? mapping[@"config_name"] : @"";
    NSString *parameterName = [mapping[@"parameter_name"] isKindOfClass:NSString.class]
        ? mapping[@"parameter_name"] : @"";
    NSString *key = configName.length
        ? [NSString stringWithFormat:@"%llu:%@", externalID, configName]
        : [NSString stringWithFormat:@"%llu:", externalID];
    NSString *row = parameterName.length
        ? [NSString stringWithFormat:@"%u: %@: %@", parameterIndex, parameterName, valueString]
        : [NSString stringWithFormat:@"%u: : %@", parameterIndex, valueString];

    NSDictionary *incoming = @{ key : @[row], @"_qe_overrides_" : @[] };
    NSString *writeDiagnostic = nil;
    BOOL ok = WAGRMobileConfigNativeWriteOverrideDocument(incoming, userContext, YES,
                                                           outError, &writeDiagnostic);
    if (outDiagnostic) {
        *outDiagnostic = [NSString stringWithFormat:@"%@; %@",
            mappingDiagnostic ?: @"", writeDiagnostic ?: (ok ? @"written" : @"write failed")];
    }
    return ok;
}

BOOL WAGRABPropsNativeClearOverride(NSString *waStableID,
                                    id userContext,
                                    NSError **outError,
                                    NSString **outDiagnostic) {
    NSString *mappingDiagnostic = nil;
    NSDictionary *mapping = WAGRABPropsNativeOverrideMapping(waStableID, userContext,
                                                              &mappingDiagnostic);
    if (!mapping) {
        if (outError) *outError = WAGRABNativeError(3, mappingDiagnostic);
        if (outDiagnostic) *outDiagnostic = mappingDiagnostic;
        return NO;
    }

    unsigned long long externalID = [mapping[@"external_config_stable_id"] unsignedLongLongValue];
    NSInteger parameterIndex = [mapping[@"parameter_index"] integerValue];
    NSString *wanted = [NSString stringWithFormat:@"%llu", externalID];
    NSDictionary *existing = WAGRABNativeReadOverrideDocument(userContext);
    if (!existing.count) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; nothing to remove", mappingDiagnostic ?: @""];
        return YES;
    }

    NSMutableDictionary *updated = [existing mutableCopy];
    BOOL removed = NO;
    for (NSString *key in existing.allKeys) {
        if (![WAGRABNativeStablePrefix(key) isEqualToString:wanted]) continue;
        NSArray *rows = [existing[key] isKindOfClass:NSArray.class] ? existing[key] : @[];
        NSMutableArray *kept = [NSMutableArray array];
        for (NSString *row in rows) {
            if (WAGRABNativeRowIndex(row) == parameterIndex) {
                removed = YES;
            } else {
                [kept addObject:row];
            }
        }
        if (kept.count) updated[key] = kept;
        else [updated removeObjectForKey:key];
    }
    if (!updated[@"_qe_overrides_"]) updated[@"_qe_overrides_"] = @[];

    if (!removed) {
        if (outDiagnostic) *outDiagnostic = [NSString stringWithFormat:@"%@; native row was not present", mappingDiagnostic ?: @""];
        return YES;
    }

    NSString *writeDiagnostic = nil;
    BOOL ok = WAGRMobileConfigNativeWriteOverrideDocument(updated, userContext, NO,
                                                           outError, &writeDiagnostic);
    if (outDiagnostic) {
        *outDiagnostic = [NSString stringWithFormat:@"%@; removed; %@",
            mappingDiagnostic ?: @"", writeDiagnostic ?: (ok ? @"written" : @"write failed")];
    }
    return ok;
}
