// WAGRABPropsCentralOverride.m
//
// Native WhatsApp ABProps are evaluated through WAProperties typed accessors.
// Current-build reverse engineering confirms the generated WAAB getter shape:
//     descriptor("1777") -> -[WAProperties boolForKey:defaultValue:]
//
// This module overlays those four typed choke points instead of installing one
// hook per generated getter. It deliberately does NOT write gabp.*p/c: those are
// WhatsApp's server-backed WAPropertiesStore cache and metadata. WATweaks keeps
// its override registry in its own preferences domain and only changes the
// effective value returned by WAProperties.

#import "WAGRABPropsCentralOverride.h"

#import <objc/runtime.h>
#import <substrate.h>
#include <stdint.h>
#include <string.h>

static NSString * const kWAGRABCentralDefaultsKey = @"watweak_abprops_central_overrides_v1";

static NSDictionary<NSString *, NSDictionary *> *gWAGRABCentralSnapshot = nil;
static NSObject *gWAGRABCentralMutationLock = nil;
static uint32_t gWAGRABCentralInstalledMask = 0;

static BOOL (*gWAGRABOriginalBool)(id, SEL, id, BOOL) = NULL;
static int64_t (*gWAGRABOriginalInteger)(id, SEL, id, int64_t) = NULL;
static double (*gWAGRABOriginalDouble)(id, SEL, id, double) = NULL;
static id (*gWAGRABOriginalString)(id, SEL, id, id) = NULL;

static const char *WAGRABCentralSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABCentralDecimalString(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return NO;
    return [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static NSString *WAGRABCentralCanonicalType(NSString *type) {
    NSString *lower = [type.lowercaseString stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!lower.length) return nil;
    if ([lower isEqualToString:@"bool"] || [type isEqualToString:@"B"] ||
        [type isEqualToString:@"c"] || [type isEqualToString:@"C"]) return @"bool";
    if ([lower isEqualToString:@"int"] || [lower isEqualToString:@"integer"] ||
        [lower isEqualToString:@"int64"] || [lower isEqualToString:@"uint64"] ||
        [@[@"q", @"Q", @"l", @"L", @"i", @"I", @"s", @"S"] containsObject:type]) return @"int";
    if ([lower isEqualToString:@"double"] || [lower isEqualToString:@"float"] ||
        [type isEqualToString:@"d"] || [type isEqualToString:@"f"]) return @"double";
    if ([lower isEqualToString:@"string"] || [lower isEqualToString:@"nsstring"] ||
        [type isEqualToString:@"@"]) return @"string";
    return nil;
}

static BOOL WAGRABCentralValueMatchesType(NSString *type, id value) {
    if ([type isEqualToString:@"string"]) return [value isKindOfClass:NSString.class];
    return [value isKindOfClass:NSNumber.class];
}

static void WAGRABCentralLoadSnapshot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRABCentralMutationLock = [NSObject new];
        id raw = [NSUserDefaults.standardUserDefaults objectForKey:kWAGRABCentralDefaultsKey];
        NSMutableDictionary *validated = [NSMutableDictionary dictionary];
        if ([raw isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id object, __unused BOOL *stop) {
                NSString *code = [key isKindOfClass:NSString.class] ? key : nil;
                NSDictionary *spec = [object isKindOfClass:NSDictionary.class] ? object : nil;
                NSString *type = WAGRABCentralCanonicalType(spec[@"type"]);
                id value = spec[@"value"];
                if (WAGRABCentralDecimalString(code) && type.length &&
                    WAGRABCentralValueMatchesType(type, value)) {
                    validated[code] = @{ @"type": type, @"value": value };
                }
            }];
        }
        gWAGRABCentralSnapshot = [validated copy];
    });
}

static NSDictionary *WAGRABCentralSpecForKey(id key, NSString *expectedType) {
    // No defaults/reflection/locks in the evaluation hot path. The immutable
    // snapshot is loaded before any central method hook is installed.
    if (![key isKindOfClass:NSString.class]) return nil;
    NSString *code = (NSString *)key;
    if (!WAGRABCentralDecimalString(code)) return nil;
    NSDictionary *spec = gWAGRABCentralSnapshot[code];
    if (![spec[@"type"] isEqualToString:expectedType]) return nil;
    return spec;
}

static BOOL WAGRABCentralBool(id self, SEL _cmd, id key, BOOL defaultValue) {
    BOOL original = gWAGRABOriginalBool ? gWAGRABOriginalBool(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *spec = WAGRABCentralSpecForKey(key, @"bool");
    id value = spec[@"value"];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : original;
}

static int64_t WAGRABCentralInteger(id self, SEL _cmd, id key, int64_t defaultValue) {
    int64_t original = gWAGRABOriginalInteger ? gWAGRABOriginalInteger(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *spec = WAGRABCentralSpecForKey(key, @"int");
    id value = spec[@"value"];
    return [value isKindOfClass:NSNumber.class] ? [value longLongValue] : original;
}

static double WAGRABCentralDouble(id self, SEL _cmd, id key, double defaultValue) {
    double original = gWAGRABOriginalDouble ? gWAGRABOriginalDouble(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *spec = WAGRABCentralSpecForKey(key, @"double");
    id value = spec[@"value"];
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : original;
}

static id WAGRABCentralString(id self, SEL _cmd, id key, id defaultValue) {
    id original = gWAGRABOriginalString ? gWAGRABOriginalString(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *spec = WAGRABCentralSpecForKey(key, @"string");
    id value = spec[@"value"];
    return [value isKindOfClass:NSString.class] ? value : original;
}

static char WAGRABCentralReturnType(Method method) {
    char raw[64] = {0};
    if (!method) return '\0';
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABCentralSkipQualifiers(raw)[0];
}

static char WAGRABCentralArgumentType(Method method, unsigned int index) {
    char raw[64] = {0};
    if (!method || index >= method_getNumberOfArguments(method)) return '\0';
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRABCentralSkipQualifiers(raw)[0];
}

static BOOL WAGRABCentralWordIs64Bit(Method method, BOOL returnValue, unsigned int argumentIndex) {
    char raw[64] = {0};
    if (!method) return NO;
    if (returnValue) method_getReturnType(method, raw, sizeof(raw));
    else if (argumentIndex < method_getNumberOfArguments(method)) method_getArgumentType(method, argumentIndex, raw, sizeof(raw));
    else return NO;
    const char *type = WAGRABCentralSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size == sizeof(int64_t);
}

static BOOL WAGRABCentralValidateCommon(Method method) {
    return method && method_getNumberOfArguments(method) == 4 &&
           WAGRABCentralArgumentType(method, 2) == '@';
}

static uint32_t WAGRABCentralInstallLocked(Class cls) {
    if (!cls) return gWAGRABCentralInstalledMask;

    SEL boolSel = NSSelectorFromString(@"boolForKey:defaultValue:");
    Method boolMethod = class_getInstanceMethod(cls, boolSel);
    if (!(gWAGRABCentralInstalledMask & 1u) && WAGRABCentralValidateCommon(boolMethod)) {
        char r = WAGRABCentralReturnType(boolMethod);
        char a = WAGRABCentralArgumentType(boolMethod, 3);
        if ((r == 'B' || r == 'c' || r == 'C') && (a == 'B' || a == 'c' || a == 'C')) {
            MSHookMessageEx(cls, boolSel, (IMP)WAGRABCentralBool, (IMP *)&gWAGRABOriginalBool);
            gWAGRABCentralInstalledMask |= 1u;
        }
    }

    SEL intSel = NSSelectorFromString(@"integerForKey:defaultValue:");
    Method intMethod = class_getInstanceMethod(cls, intSel);
    if (!(gWAGRABCentralInstalledMask & 2u) && WAGRABCentralValidateCommon(intMethod) &&
        WAGRABCentralWordIs64Bit(intMethod, YES, 0) && WAGRABCentralWordIs64Bit(intMethod, NO, 3)) {
        MSHookMessageEx(cls, intSel, (IMP)WAGRABCentralInteger, (IMP *)&gWAGRABOriginalInteger);
        gWAGRABCentralInstalledMask |= 2u;
    }

    SEL doubleSel = NSSelectorFromString(@"doubleForKey:defaultValue:");
    Method doubleMethod = class_getInstanceMethod(cls, doubleSel);
    if (!(gWAGRABCentralInstalledMask & 4u) && WAGRABCentralValidateCommon(doubleMethod) &&
        WAGRABCentralReturnType(doubleMethod) == 'd' && WAGRABCentralArgumentType(doubleMethod, 3) == 'd') {
        MSHookMessageEx(cls, doubleSel, (IMP)WAGRABCentralDouble, (IMP *)&gWAGRABOriginalDouble);
        gWAGRABCentralInstalledMask |= 4u;
    }

    SEL stringSel = NSSelectorFromString(@"stringForKey:defaultValue:");
    Method stringMethod = class_getInstanceMethod(cls, stringSel);
    if (!(gWAGRABCentralInstalledMask & 8u) && WAGRABCentralValidateCommon(stringMethod) &&
        WAGRABCentralReturnType(stringMethod) == '@' && WAGRABCentralArgumentType(stringMethod, 3) == '@') {
        MSHookMessageEx(cls, stringSel, (IMP)WAGRABCentralString, (IMP *)&gWAGRABOriginalString);
        gWAGRABCentralInstalledMask |= 8u;
    }
    return gWAGRABCentralInstalledMask;
}

BOOL WAGRABPropsCentralEnsureInstalled(void) {
    WAGRABCentralLoadSnapshot();
    @synchronized (gWAGRABCentralMutationLock) {
        Class cls = NSClassFromString(@"WAProperties") ?: objc_getClass("WAProperties");
        uint32_t mask = WAGRABCentralInstallLocked(cls);
        return (mask & 1u) != 0;
    }
}

static void WAGRABCentralPersistSnapshot(NSDictionary *snapshot) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (snapshot.count) [defaults setObject:snapshot forKey:kWAGRABCentralDefaultsKey];
    else [defaults removeObjectForKey:kWAGRABCentralDefaultsKey];
    [defaults synchronize];
}

BOOL WAGRABPropsCentralSetOverride(NSString *code, NSString *type, id value) {
    WAGRABCentralLoadSnapshot();
    NSString *canonicalType = WAGRABCentralCanonicalType(type);
    if (!WAGRABCentralDecimalString(code) || !canonicalType.length ||
        !WAGRABCentralValueMatchesType(canonicalType, value)) return NO;

    @synchronized (gWAGRABCentralMutationLock) {
        NSMutableDictionary *next = [gWAGRABCentralSnapshot mutableCopy] ?: [NSMutableDictionary dictionary];
        next[code] = @{ @"type": canonicalType, @"value": value };
        gWAGRABCentralSnapshot = [next copy];
        WAGRABCentralPersistSnapshot(gWAGRABCentralSnapshot);
    }
    return WAGRABPropsCentralEnsureInstalled();
}

void WAGRABPropsCentralClearOverride(NSString *code) {
    WAGRABCentralLoadSnapshot();
    if (!WAGRABCentralDecimalString(code)) return;
    @synchronized (gWAGRABCentralMutationLock) {
        if (!gWAGRABCentralSnapshot[code]) return;
        NSMutableDictionary *next = [gWAGRABCentralSnapshot mutableCopy];
        [next removeObjectForKey:code];
        gWAGRABCentralSnapshot = [next copy];
        WAGRABCentralPersistSnapshot(gWAGRABCentralSnapshot);
    }
}

NSUInteger WAGRABPropsCentralClearAll(void) {
    WAGRABCentralLoadSnapshot();
    @synchronized (gWAGRABCentralMutationLock) {
        NSUInteger count = gWAGRABCentralSnapshot.count;
        gWAGRABCentralSnapshot = @{};
        WAGRABCentralPersistSnapshot(gWAGRABCentralSnapshot);
        return count;
    }
}

BOOL WAGRABPropsCentralHasOverride(NSString *code) {
    WAGRABCentralLoadSnapshot();
    return WAGRABCentralDecimalString(code) && gWAGRABCentralSnapshot[code] != nil;
}

id WAGRABPropsCentralOverride(NSString *code) {
    WAGRABCentralLoadSnapshot();
    NSDictionary *spec = WAGRABCentralDecimalString(code) ? gWAGRABCentralSnapshot[code] : nil;
    return spec[@"value"];
}

NSDictionary<NSString *, NSDictionary *> *WAGRABPropsCentralAllOverrides(void) {
    WAGRABCentralLoadSnapshot();
    return gWAGRABCentralSnapshot ?: @{};
}

NSString *WAGRABPropsCentralDiagnostic(void) {
    WAGRABCentralLoadSnapshot();
    return [NSString stringWithFormat:@"central WAProperties overlay: overrides=%lu hooks=0x%02x (bool=%@ int=%@ double=%@ string=%@)",
            (unsigned long)gWAGRABCentralSnapshot.count,
            (unsigned int)gWAGRABCentralInstalledMask,
            (gWAGRABCentralInstalledMask & 1u) ? @"yes" : @"no",
            (gWAGRABCentralInstalledMask & 2u) ? @"yes" : @"no",
            (gWAGRABCentralInstalledMask & 4u) ? @"yes" : @"no",
            (gWAGRABCentralInstalledMask & 8u) ? @"yes" : @"no"];
}

__attribute__((constructor))
static void WAGRABPropsCentralCtor(void) {
    @autoreleasepool {
        WAGRABCentralLoadSnapshot();
        if (!gWAGRABCentralSnapshot.count) return;

        // Persisted overlays are the only reason to touch WAProperties at launch.
        // Four exact method lookups replace the old per-gate/per-getter scans.
        if (!WAGRABPropsCentralEnsureInstalled()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                (void)WAGRABPropsCentralEnsureInstalled();
            });
        }
    }
}
