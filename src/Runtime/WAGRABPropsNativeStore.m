#import "WAGRABPropsNativeStore.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static NSString * const kWAGRABPropsSharedSuite = @"group.net.whatsapp.WhatsApp.shared";
static NSString * const kWAGRABPropsErrorDomain = @"WATweaks.ABPropsNative";

extern NSString *WAGRWAABDisplayNameForKey(NSString *key);

@implementation WAGRABPropsNativeSnapshot
@end

#pragma mark - Diagnostics

static NSObject *gWAGRABNativeDiagnosticLock = nil;
static NSString *gWAGRABNativeDiagnostic = @"not attempted";

static void WAGRABNativeEnsureDiagnosticLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWAGRABNativeDiagnosticLock = [NSObject new]; });
}

static void WAGRABNativeSetDiagnostic(NSString *text) {
    WAGRABNativeEnsureDiagnosticLock();
    @synchronized (gWAGRABNativeDiagnosticLock) {
        gWAGRABNativeDiagnostic = [text copy] ?: @"unknown";
    }
    WAGRLogAppendF(@"[ABProps][Native] %@", text ?: @"unknown");
}

NSString *WAGRABPropsNativeDiagnosticText(void) {
    WAGRABNativeEnsureDiagnosticLock();
    @synchronized (gWAGRABNativeDiagnosticLock) {
        return [gWAGRABNativeDiagnostic copy] ?: @"unknown";
    }
}

#pragma mark - Native cache decoding

static BOOL WAGRABStringIsDecimal(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return NO;
    NSCharacterSet *nonDigits = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    return [value rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static NSDictionary *WAGRABDecodeDictionary(id raw) {
    if ([raw isKindOfClass:NSDictionary.class]) return raw;
    if (![raw isKindOfClass:NSData.class]) return nil;
    NSError *error = nil;
    id object = [NSPropertyListSerialization propertyListWithData:(NSData *)raw
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:&error];
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    return object;
}

static NSUInteger WAGRABNumericKeyCount(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return 0;
    __block NSUInteger count = 0;
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, __unused id value, __unused BOOL *stop) {
        NSString *candidate = [key isKindOfClass:NSString.class] ? key : [key description];
        if (WAGRABStringIsDecimal(candidate)) count++;
    }];
    return count;
}

static NSDictionary *WAGRABSuiteDictionary(void) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kWAGRABPropsSharedSuite];
    @try { [defaults synchronize]; } @catch (__unused NSException *exception) {}
    NSDictionary *representation = nil;
    @try { representation = defaults.dictionaryRepresentation; }
    @catch (__unused NSException *exception) { representation = nil; }
    if (representation.count) [merged addEntriesFromDictionary:representation];

    CFArrayRef keysRef = CFPreferencesCopyKeyList((__bridge CFStringRef)kWAGRABPropsSharedSuite,
                                                   kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
    NSArray *keys = CFBridgingRelease(keysRef);
    for (id keyObject in keys ?: @[]) {
        if (![keyObject isKindOfClass:NSString.class]) continue;
        NSString *key = keyObject;
        CFPropertyListRef copied = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kWAGRABPropsSharedSuite,
                                                           kCFPreferencesCurrentUser,
                                                           kCFPreferencesAnyHost);
        if (!copied) continue;
        id value = CFBridgingRelease(copied);
        if (value) merged[key] = value;
    }
    return merged;
}

static NSString *WAGRABFingerprint(NSString *payloadKey,
                                   NSDictionary *props,
                                   NSDictionary *metadata) {
    NSMutableString *material = [NSMutableString stringWithFormat:@"%@|%lu|",
                                 payloadKey ?: @"", (unsigned long)props.count];
    for (NSString *key in @[@"hash", @"refreshID", @"refreshId", @"refresh_id",
                             @"refreshDate", @"latestRefreshDate", @"clientVersion",
                             @"latestClientVersion", @"encryptedRID", @"abKey"]) {
        id value = metadata[key];
        if (value) [material appendFormat:@"%@=%@|", key, value];
    }

    NSArray<NSString *> *sortedCodes = [props.allKeys sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        unsigned long long a = [[left description] longLongValue];
        unsigned long long b = [[right description] longLongValue];
        if (a < b) return NSOrderedAscending;
        if (a > b) return NSOrderedDescending;
        return [[left description] compare:[right description]];
    }];
    NSUInteger stride = MAX((NSUInteger)1, sortedCodes.count / 256);
    for (NSUInteger index = 0; index < sortedCodes.count; index += stride) {
        NSString *code = [sortedCodes[index] description];
        id value = props[sortedCodes[index]];
        [material appendFormat:@"%@=%@|", code, value];
    }
    return [NSString stringWithFormat:@"%016lx", (unsigned long)material.hash];
}

WAGRABPropsNativeSnapshot *WAGRABPropsReadNativeSnapshot(NSError **outError) {
    NSDictionary *suite = WAGRABSuiteDictionary();
    NSString *bestKey = nil;
    NSDictionary *bestProps = nil;
    NSUInteger bestCount = 0;

    for (id keyObject in suite) {
        if (![keyObject isKindOfClass:NSString.class]) continue;
        NSString *key = keyObject;
        NSString *lower = key.lowercaseString;
        if (![lower hasPrefix:@"gabp."] || ![lower hasSuffix:@"p"] ||
            [lower containsString:@"none"]) continue;
        NSDictionary *decoded = WAGRABDecodeDictionary(suite[key]);
        NSUInteger numericCount = WAGRABNumericKeyCount(decoded);
        if (numericCount > bestCount) {
            bestCount = numericCount;
            bestKey = key;
            bestProps = decoded;
        }
    }

    if (!bestKey.length || !bestProps.count || !bestCount) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Nenhum payload account-scoped gabp.*p foi encontrado em group.net.whatsapp.WhatsApp.shared. O WhatsApp precisa estar logado e ter concluído ao menos um sync de ABProps."}];
        }
        WAGRABNativeSetDiagnostic([NSString stringWithFormat:
            @"native cache not found; suiteKeys=%lu", (unsigned long)suite.count]);
        return nil;
    }

    NSString *metadataKey = nil;
    NSDictionary *metadata = @{};
    if (bestKey.length > 1) {
        NSString *candidate = [[bestKey substringToIndex:bestKey.length - 1] stringByAppendingString:@"c"];
        NSDictionary *decoded = WAGRABDecodeDictionary(suite[candidate]);
        if (decoded) {
            metadataKey = candidate;
            metadata = decoded;
        }
    }

    WAGRABPropsNativeSnapshot *snapshot = [WAGRABPropsNativeSnapshot new];
    snapshot.suiteName = kWAGRABPropsSharedSuite;
    snapshot.payloadKey = bestKey;
    snapshot.metadataKey = metadataKey;
    snapshot.props = bestProps;
    snapshot.metadata = metadata ?: @{};
    snapshot.loadedAt = [NSDate date];
    snapshot.numericPropCount = bestCount;
    snapshot.fingerprint = WAGRABFingerprint(bestKey, bestProps, metadata ?: @{});

    WAGRABNativeSetDiagnostic([NSString stringWithFormat:
        @"cache payload=%@ props=%lu metadata=%@ fingerprint=%@",
        bestKey, (unsigned long)bestCount, metadataKey ?: @"none", snapshot.fingerprint]);
    return snapshot;
}

#pragma mark - Name and MobileConfig enrichment

NSString *WAGRABPropsDisplayNameForCode(NSString *code) {
    if (!code.length) return @"";
    NSString *name = nil;
    @try { name = WAGRWAABDisplayNameForKey(code); }
    @catch (__unused NSException *exception) { name = nil; }
    if (!name.length || [name isEqualToString:code]) {
        return [NSString stringWithFormat:@"ABProp %@", code];
    }
    return name;
}

static const char *WAGRABSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABMethodWordArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRABSkipQualifiers(raw);
    NSUInteger size = 0, alignment = 0;
    if (!*type) return NO;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRABMethodWordReturn(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRABSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static uint64_t WAGRABMCSpecifierForCode(unsigned long long code) {
    Class cls = NSClassFromString(@"WAMCEvaluation");
    SEL selector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method method = class_getClassMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABMethodWordArgument(method, 2) || !WAGRABMethodWordReturn(method)) return 0;
    @try {
        return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)cls, selector, (uint64_t)code);
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static id WAGRABJSONSafe(id value) {
    if (!value || value == NSNull.null) return NSNull.null;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDate.class]) return [(NSDate *)value description];
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSData.class]) return [(NSData *)value base64EncodedStringWithOptions:0] ?: @"";
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id item in (NSArray *)value) [array addObject:WAGRABJSONSafe(item) ?: NSNull.null];
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, __unused BOOL *stop) {
            NSString *safeKey = [key isKindOfClass:NSString.class] ? key : [key description];
            if (safeKey.length) dictionary[safeKey] = WAGRABJSONSafe(object) ?: NSNull.null;
        }];
        return dictionary;
    }
    return [value description] ?: @"";
}

NSDictionary<NSString *, id> *WAGRABPropsNativeExportDocument(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{};
    NSArray *sortedKeys = [snapshot.props.allKeys sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        unsigned long long a = [[left description] longLongValue];
        unsigned long long b = [[right description] longLongValue];
        if (a < b) return NSOrderedAscending;
        if (a > b) return NSOrderedDescending;
        return [[left description] compare:[right description]];
    }];

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:sortedKeys.count];
    for (id keyObject in sortedKeys) {
        NSString *code = [keyObject description];
        if (!WAGRABStringIsDecimal(code)) continue;
        id rawEntry = snapshot.props[keyObject];
        NSDictionary *entryDictionary = [rawEntry isKindOfClass:NSDictionary.class] ? rawEntry : @{};
        id wireValue = entryDictionary[@"value"] ?: rawEntry ?: NSNull.null;
        uint64_t specifier = WAGRABMCSpecifierForCode(strtoull(code.UTF8String ?: "0", NULL, 10));

        NSMutableDictionary *entry = [@{
            @"code" : @([code longLongValue]),
            @"name" : WAGRABPropsDisplayNameForCode(code),
            @"value" : WAGRABJSONSafe(wireValue),
            @"native_entry" : WAGRABJSONSafe(rawEntry),
        } mutableCopy];
        if (entryDictionary[@"expoKey"]) entry[@"expoKey"] = WAGRABJSONSafe(entryDictionary[@"expoKey"]);
        if (specifier && !(specifier & (1ULL << 62))) {
            entry[@"mobileconfig"] = @{
                @"param_specifier_hex" : [NSString stringWithFormat:@"0x%016llx", specifier],
                @"local_config_index" : @((specifier >> 32) & 0xFFFF),
                @"parameter_index" : @((specifier >> 16) & 0xFFFF),
                @"parameter_stable_id" : @(specifier & 0xFFFF),
                @"native_type" : @((specifier >> 48) & 0x3F),
            };
        }
        [entries addObject:entry];
    }

    return @{
        @"format" : @"WATweaks WhatsApp native ABProps snapshot v1",
        @"source" : @"group.net.whatsapp.WhatsApp.shared / account-scoped gabp.*p",
        @"suite" : snapshot.suiteName ?: kWAGRABPropsSharedSuite,
        @"payload_key" : snapshot.payloadKey ?: @"",
        @"metadata_key" : snapshot.metadataKey ?: NSNull.null,
        @"prop_count" : @(snapshot.numericPropCount),
        @"fingerprint" : snapshot.fingerprint ?: @"",
        @"loaded_at" : snapshot.loadedAt.description ?: @"",
        @"metadata" : WAGRABJSONSafe(snapshot.metadata ?: @{}),
        @"entries" : entries,
    };
}

#pragma mark - Native fetch resolver

static BOOL WAGRABClassNameInteresting(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"abprop"] ||
           [lower containsString:@"abpropert"] ||
           [lower containsString:@"getabprops"] ||
           [lower containsString:@"fetchabprops"];
}

static id WAGRABCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char raw[32] = {0}; method_getReturnType(method, raw, sizeof(raw));
    if (WAGRABSkipQualifiers(raw)[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABSharedObjectForClass(Class cls) {
    if (!cls) return nil;
    for (NSString *selectorName in @[@"shared", @"sharedInstance", @"current", @"defaultManager", @"manager"]) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getClassMethod(cls, selector);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char raw[32] = {0}; method_getReturnType(method, raw, sizeof(raw));
        if (WAGRABSkipQualifiers(raw)[0] != '@') continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)((id)cls, selector);
            if (value) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void WAGRABCollectFetchTargets(id root,
                                      NSMutableOrderedSet *targets,
                                      NSMutableSet<NSValue *> *visited,
                                      NSUInteger depth) {
    if (!root || depth > 4) return;
    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    NSString *className = NSStringFromClass([root class]) ?: @"";
    if (WAGRABClassNameInteresting(className)) [targets addObject:root];

    for (NSString *selectorName in @[
        @"abPropsRequestManager", @"abPropertiesRequestManager", @"abPropsManager",
        @"abProperties", @"waABProperties", @"xmppConnection", @"connection",
        @"syncManager", @"propertiesManager", @"userContext"
    ]) {
        id child = WAGRABCallObjectNoArg(root, selectorName);
        if (!child || child == root) continue;
        NSString *childName = NSStringFromClass([child class]) ?: @"";
        if (WAGRABClassNameInteresting(childName)) [targets addObject:child];
        WAGRABCollectFetchTargets(child, targets, visited, depth + 1);
    }

    for (Class current = [root class]; current && current != NSObject.class;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *type = ivar_getTypeEncoding(ivar);
            const char *name = ivar_getName(ivar);
            if (!type || !name || WAGRABSkipQualifiers(type)[0] != '@') continue;
            NSString *ivarName = [[NSString stringWithUTF8String:name] lowercaseString] ?: @"";
            if (!([ivarName containsString:@"abprop"] || [ivarName containsString:@"xmpp"] ||
                  [ivarName containsString:@"sync"] || [ivarName containsString:@"connection"])) continue;
            id child = nil;
            @try { child = object_getIvar(root, ivar); }
            @catch (__unused NSException *exception) { child = nil; }
            if (!child || child == root) continue;
            NSString *childName = NSStringFromClass([child class]) ?: @"";
            if (WAGRABClassNameInteresting(childName)) [targets addObject:child];
            WAGRABCollectFetchTargets(child, targets, visited, depth + 1);
        }
        free(ivars);
    }
}

static BOOL WAGRABReturnTypeSafeForDiscard(Method method) {
    if (!method) return NO;
    char raw[64] = {0}; method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRABSkipQualifiers(raw)[0]) {
        case 'v': case '@': case 'B': case 'c': case 'C':
        case 's': case 'S': case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
            return YES;
        default:
            return NO;
    }
}

static BOOL WAGRABMethodObjectArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0}; method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRABSkipQualifiers(raw)[0] == '@';
}

static NSInteger WAGRABFetchSelectorScore(NSString *className, NSString *selectorName, Method method) {
    if (!selectorName.length || !method || !WAGRABReturnTypeSafeForDiscard(method)) return NSIntegerMin;
    unsigned int argc = method_getNumberOfArguments(method);
    if (argc != 2 && argc != 3) return NSIntegerMin;

    NSString *lowerClass = className.lowercaseString ?: @"";
    NSString *lower = selectorName.lowercaseString ?: @"";
    if ([lower hasPrefix:@"init"] || [lower hasPrefix:@"dealloc"] || [lower containsString:@"cancel"] ||
        [lower containsString:@"snapshot"] || [lower containsString:@"currentvalue"] ||
        [lower hasPrefix:@"is"] || [lower hasPrefix:@"should"] || [lower hasPrefix:@"can"]) return NSIntegerMin;

    BOOL verb = [lower containsString:@"fetch"] || [lower containsString:@"sync"] ||
                [lower containsString:@"refresh"] || [lower containsString:@"request"] ||
                [lower isEqualToString:@"getabprops"];
    BOOL ab = [lower containsString:@"abprop"] || [lowerClass containsString:@"abprop"] ||
              [lowerClass containsString:@"abpropert"];
    if (!verb || !ab) return NSIntegerMin;

    if (argc == 3) {
        if (!WAGRABMethodObjectArgument(method, 2)) return NSIntegerMin;
        NSString *label = [[selectorName componentsSeparatedByString:@":"] firstObject].lowercaseString ?: @"";
        if (![label containsString:@"context"]) return NSIntegerMin;
    }

    NSInteger score = 0;
    if ([lower containsString:@"abprop"]) score += 50;
    if ([lower containsString:@"fetch"]) score += 40;
    if ([lower containsString:@"sync"]) score += 35;
    if ([lower containsString:@"refresh"]) score += 30;
    if ([lower containsString:@"request"]) score += 25;
    if ([lowerClass containsString:@"requestmanager"]) score += 30;
    if ([lowerClass containsString:@"fetchabprops"]) score += 25;
    if ([lowerClass containsString:@"sync"]) score += 15;
    if (argc == 2) score += 20;
    return score;
}

static BOOL WAGRABInvokeFetchOnTarget(id target,
                                      BOOL classMethods,
                                      id userContext,
                                      NSString **source) {
    if (!target) return NO;
    Class owner = classMethods ? object_getClass((Class)target) : [target class];
    NSString *className = classMethods ? NSStringFromClass((Class)target) : NSStringFromClass([target class]);
    Method bestMethod = NULL;
    SEL bestSelector = NULL;
    NSInteger bestScore = NSIntegerMin;

    for (Class current = owner; current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            Method method = methods[index];
            SEL selector = method_getName(method);
            NSString *selectorName = NSStringFromSelector(selector);
            NSInteger score = WAGRABFetchSelectorScore(className, selectorName, method);
            if (score > bestScore) {
                bestScore = score;
                bestMethod = method;
                bestSelector = selector;
            }
        }
        free(methods);
    }

    if (!bestMethod || !bestSelector || bestScore == NSIntegerMin) return NO;
    unsigned int argc = method_getNumberOfArguments(bestMethod);
    NSString *selectorName = NSStringFromSelector(bestSelector);
    @try {
        if (argc == 2) {
            ((void (*)(id, SEL))objc_msgSend)(target, bestSelector);
        } else if (argc == 3 && userContext) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, bestSelector, userContext);
        } else {
            return NO;
        }
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][Fetch] %@.%@ threw %@",
                       className ?: @"?", selectorName ?: @"?", exception.reason ?: @"exception");
        return NO;
    }

    if (source) {
        *source = [NSString stringWithFormat:@"%@%@.%@ score=%ld",
                   classMethods ? @"+" : @"-", className ?: @"?",
                   selectorName ?: @"?", (long)bestScore];
    }
    return YES;
}

BOOL WAGRABPropsTriggerNativeFetch(id userContext, NSString **diagnostic) {
    NSMutableOrderedSet *targets = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    WAGRABCollectFetchTargets(userContext, targets, visited, 0);

    NSArray<NSString *> *knownClassNames = @[
        @"XMPPConnectionABPropsRequestManager",
        @"WAABPropsRequestManager",
        @"WAABPropertiesRequestManager",
        @"FetchABPropsStateResource",
        @"WABackupABPropsRefreshPlugin",
        @"BackupABPropsRefreshPlugin"
    ];
    for (NSString *name in knownClassNames) {
        Class cls = NSClassFromString(name) ?: objc_getClass(name.UTF8String);
        if (!cls) continue;
        id shared = WAGRABSharedObjectForClass(cls);
        if (shared) [targets addObject:shared];
    }

    unsigned int classCount = 0;
    __unsafe_unretained Class *runtimeClasses = objc_copyClassList(&classCount);
    NSMutableOrderedSet *candidateClasses = [NSMutableOrderedSet orderedSet];
    for (unsigned int index = 0; index < classCount; index++) {
        Class cls = runtimeClasses[index];
        NSString *name = NSStringFromClass(cls) ?: @"";
        if (WAGRABClassNameInteresting(name) &&
            ([name.lowercaseString containsString:@"request"] ||
             [name.lowercaseString containsString:@"fetch"] ||
             [name.lowercaseString containsString:@"sync"] ||
             [name.lowercaseString containsString:@"refresh"])) {
            [candidateClasses addObject:cls];
        }
    }
    free(runtimeClasses);

    NSString *source = nil;
    for (id target in targets) {
        if (WAGRABInvokeFetchOnTarget(target, NO, userContext, &source)) {
            NSString *text = [NSString stringWithFormat:@"native fetch invoked via %@ targets=%lu",
                              source ?: @"unknown", (unsigned long)targets.count];
            WAGRABNativeSetDiagnostic(text);
            if (diagnostic) *diagnostic = text;
            return YES;
        }
    }

    for (Class cls in candidateClasses) {
        if (WAGRABInvokeFetchOnTarget((id)cls, YES, userContext, &source)) {
            NSString *text = [NSString stringWithFormat:@"native fetch invoked via %@ classCandidates=%lu",
                              source ?: @"unknown", (unsigned long)candidateClasses.count];
            WAGRABNativeSetDiagnostic(text);
            if (diagnostic) *diagnostic = text;
            return YES;
        }
        id shared = WAGRABSharedObjectForClass(cls);
        if (shared && WAGRABInvokeFetchOnTarget(shared, NO, userContext, &source)) {
            NSString *text = [NSString stringWithFormat:@"native fetch invoked via %@ classCandidates=%lu",
                              source ?: @"unknown", (unsigned long)candidateClasses.count];
            WAGRABNativeSetDiagnostic(text);
            if (diagnostic) *diagnostic = text;
            return YES;
        }
    }

    NSString *text = [NSString stringWithFormat:
        @"native fetch entrypoint not resolved (targets=%lu classes=%lu). The live account cache remains readable/exportable; open/use WhatsApp's native Developer/Internal ABProps flow once and retry Fetch.",
        (unsigned long)targets.count, (unsigned long)candidateClasses.count];
    WAGRABNativeSetDiagnostic(text);
    if (diagnostic) *diagnostic = text;
    return NO;
}
