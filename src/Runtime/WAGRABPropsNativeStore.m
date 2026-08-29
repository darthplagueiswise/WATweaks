#import "WAGRABPropsNativeStore.h"
#import "WAGRABPropsCanonicalNamesV2.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRUserContextLinkage.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <stddef.h>
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

#pragma mark - Shared ABI helpers

static const char *WAGRABSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRABMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRABSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRABMethodReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRABSkipQualifiers(raw)[0]) {
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q': return YES;
        default: return NO;
    }
}

static BOOL WAGRABMethodWordArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRABSkipQualifiers(raw);
    if (!*type) return NO;
    NSUInteger size = 0, alignment = 0;
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

static id WAGRABCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRABMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRABCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRABMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
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
    id object = [NSPropertyListSerialization propertyListWithData:(NSData *)raw
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
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
    @try {
        NSDictionary *representation = defaults.dictionaryRepresentation;
        if (representation.count) [merged addEntriesFromDictionary:representation];
    } @catch (__unused NSException *exception) {}

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

static NSString *WAGRABFingerprint(NSString *payloadKey, NSDictionary *props, NSDictionary *metadata) {
    NSMutableString *material = [NSMutableString stringWithFormat:@"%@|%lu|",
                                 payloadKey ?: @"", (unsigned long)props.count];
    for (NSString *key in @[@"hash", @"refreshID", @"refreshId", @"refresh_id",
                             @"refreshDate", @"latestRefreshDate", @"clientVersion",
                             @"latestClientVersion", @"encryptedRID", @"abKey"]) {
        id value = metadata[key];
        if (value) [material appendFormat:@"%@=%@|", key, value];
    }
    NSArray *sortedCodes = [props.allKeys sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        unsigned long long a = [[left description] longLongValue];
        unsigned long long b = [[right description] longLongValue];
        if (a < b) return NSOrderedAscending;
        if (a > b) return NSOrderedDescending;
        return [[left description] compare:[right description]];
    }];
    NSUInteger stride = MAX((NSUInteger)1, sortedCodes.count / 256);
    for (NSUInteger index = 0; index < sortedCodes.count; index += stride) {
        NSString *code = [sortedCodes[index] description];
        [material appendFormat:@"%@=%@|", code, props[sortedCodes[index]]];
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
        if (![lower hasPrefix:@"gabp."] || ![lower hasSuffix:@"p"] || [lower containsString:@"none"]) continue;
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
        WAGRABNativeSetDiagnostic([NSString stringWithFormat:@"native cache not found; suiteKeys=%lu",
                                   (unsigned long)suite.count]);
        return nil;
    }

    NSString *metadataKey = nil;
    NSDictionary *metadata = @{};
    NSString *candidate = [[bestKey substringToIndex:bestKey.length - 1] stringByAppendingString:@"c"];
    NSDictionary *decodedMetadata = WAGRABDecodeDictionary(suite[candidate]);
    if (decodedMetadata) {
        metadataKey = candidate;
        metadata = decodedMetadata;
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
    snapshot.sourceKind = @"diagnostic_app_group_scan_unattributed";
    snapshot.storePropertiesType = NSNotFound;
    WAGRABNativeSetDiagnostic([NSString stringWithFormat:@"cache payload=%@ props=%lu metadata=%@ fingerprint=%@",
                               bestKey, (unsigned long)bestCount,
                               metadataKey ?: @"none", snapshot.fingerprint]);
    return snapshot;
}


#pragma mark - Exact WAPropertiesStore snapshot

static id WAGRABObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type && type[0] && type[0] != '@') return nil;
    @try { return object_getIvar(object, ivar); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRABReadPropertiesType(id store, NSInteger *value, NSString **diagnostic) {
    if (value) *value = NSNotFound;
    Ivar ivar = store ? class_getInstanceVariable([store class], "propertiesType") : NULL;
    if (!ivar || ivar_getOffset(ivar) != 48) {
        if (diagnostic) *diagnostic = @"propertiesType ivar/offset is not +0x30";
        return NO;
    }

    // Both supplied SharedModules(5)/(6) builds deliberately have an empty
    // type-encoding c-string for WAPropertiesStore's local ivars. The ivar-list entry still proves
    // offset=0x30, alignment=3 and size=8, while the designated initializer
    // independently proves that propertiesType is the q argument at +48:
    // @68@0:8@16@24@32@40q48@56B64. Do not reject the correct object merely
    // because ivar_getTypeEncoding returns the stripped empty string.
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (encoding && encoding[0] && encoding[0] != 'q' && encoding[0] != 'Q') {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:
                @"propertiesType has unexpected runtime encoding %s", encoding];
        }
        return NO;
    }
    Method initializer = class_getInstanceMethod([store class],
        NSSelectorFromString(@"initWithPreferencesStore:accountProvider:userContext:kvStoreNamespace:propertiesType:groupJID:encryptProperties:"));
    const char *initializerEncoding = initializer ? method_getTypeEncoding(initializer) : NULL;
    if (!initializerEncoding || strcmp(initializerEncoding,
            "@68@0:8@16@24@32@40q48@56B64") != 0) {
        if (diagnostic) *diagnostic = @"WAPropertiesStore designated initializer ABI mismatch";
        return NO;
    }
    int64_t raw = 0;
    memcpy(&raw, ((const uint8_t *)(__bridge const void *)store) + 48, sizeof(raw));
    if (value) *value = (NSInteger)raw;
    return YES;
}

WAGRABPropsNativeSnapshot *WAGRABPropsReadNativeSnapshotForProperties(
    id properties, NSError **outError) {
    if (!properties) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:10
            userInfo:@{NSLocalizedDescriptionKey:@"WAProperties account-scoped não resolvido."}];
        return nil;
    }

    Class propertiesBase = NSClassFromString(@"WAProperties");
    if (!propertiesBase || ![properties isKindOfClass:propertiesBase]) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:16
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Objeto account-scoped não pertence a WAProperties (classe=%@).",
                    NSStringFromClass([properties class]) ?: @"nil"]}];
        return nil;
    }

    id store = WAGRABCallObjectNoArg(properties, @"propertiesStore");
    Ivar ownerIvar = class_getInstanceVariable([properties class], "_propertiesStore");
    id ownerStore = ownerIvar ? WAGRABObjectIvar(properties, "_propertiesStore") : nil;
    if (!ownerIvar || ivar_getOffset(ownerIvar) != 8 || !store ||
        (ownerStore && store != ownerStore)) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:11
            userInfo:@{NSLocalizedDescriptionKey:
                @"Layout/identidade de WAProperties._propertiesStore divergiu; leitura exata recusada."}];
        return nil;
    }

    Class storeBase = NSClassFromString(@"WAPropertiesStore");
    if (!storeBase || ![store isKindOfClass:storeBase] || class_getInstanceSize([store class]) < 0xE8) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:17
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"propertiesStore não é o WAPropertiesStore esperado (classe=%@ size=0x%lx).",
                    NSStringFromClass([store class]) ?: @"nil",
                    (unsigned long)(store ? class_getInstanceSize([store class]) : 0)]}];
        return nil;
    }

    Ivar preferencesIvar = class_getInstanceVariable([store class], "preferencesStore");
    Ivar namespaceIvar = class_getInstanceVariable([store class], "namespace");
    Ivar typeIvar = class_getInstanceVariable([store class], "propertiesType");
    Ivar groupIvar = class_getInstanceVariable([store class], "groupJID");
    Ivar propsIvar = class_getInstanceVariable([store class], "properties");
    if (!preferencesIvar || ivar_getOffset(preferencesIvar) != 8 ||
        !namespaceIvar || ivar_getOffset(namespaceIvar) != 32 ||
        !typeIvar || ivar_getOffset(typeIvar) != 48 ||
        !groupIvar || ivar_getOffset(groupIvar) != 56 ||
        !propsIvar || ivar_getOffset(propsIvar) != 96) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:12
            userInfo:@{NSLocalizedDescriptionKey:
                @"Layout de WAPropertiesStore difere do SharedModules analisado; leitura exata recusada."}];
        return nil;
    }

    id rawProps = WAGRABObjectIvar(store, "properties");
    if (![rawProps isKindOfClass:NSDictionary.class]) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:13
            userInfo:@{NSLocalizedDescriptionKey:
                @"WAPropertiesStore.properties não é o dicionário nativo esperado."}];
        return nil;
    }
    NSDictionary *props = [(NSDictionary *)rawProps copy];
    NSUInteger numericCount = WAGRABNumericKeyCount(props);
    if (!numericCount) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:14
            userInfo:@{NSLocalizedDescriptionKey:
                @"O WAPropertiesStore exato não contém ABProps numéricas."}];
        return nil;
    }

    id namespaceValue = WAGRABObjectIvar(store, "namespace");
    id groupValue = WAGRABObjectIvar(store, "groupJID");
    id preferencesStore = WAGRABObjectIvar(store, "preferencesStore");
    id accountProvider = WAGRABObjectIvar(store, "accountProvider");
    id storeUserContext = WAGRABObjectIvar(store, "userContext");
    NSString *storeNamespace = [namespaceValue isKindOfClass:NSString.class]
        ? namespaceValue : [namespaceValue description];
    NSString *groupJID = [groupValue isKindOfClass:NSString.class]
        ? groupValue : [groupValue description];
    NSInteger propertiesType = NSNotFound;
    NSString *propertiesTypeDiagnostic = nil;
    if (!WAGRABReadPropertiesType(store, &propertiesType, &propertiesTypeDiagnostic)) {
        if (outError) *outError = [NSError errorWithDomain:kWAGRABPropsErrorDomain code:15
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"WAPropertiesStore.propertiesType não pôde ser lido pelo ABI provado: %@.",
                    propertiesTypeDiagnostic ?: @"falha desconhecida"]}];
        return nil;
    }

    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    for (NSString *selectorName in @[@"configKey", @"configHash", @"refreshID",
                                      @"encryptedRID", @"scheduledRefreshDate",
                                      @"exposureKey", @"exposureKeyWithTimestamps"]) {
        id value = WAGRABCallObjectNoArg(properties, selectorName);
        if (value) metadata[selectorName] = value;
    }
    if (metadata[@"configKey"]) metadata[@"key"] = metadata[@"configKey"];
    if (metadata[@"configHash"]) metadata[@"hash"] = metadata[@"configHash"];
    metadata[@"_native_store_class"] = NSStringFromClass([store class]) ?: @"";
    metadata[@"_native_store_namespace"] = storeNamespace ?: NSNull.null;
    metadata[@"_native_group_jid"] = groupJID ?: NSNull.null;
    metadata[@"_native_properties_type"] = @(propertiesType);
    const char *propertiesTypeEncoding = ivar_getTypeEncoding(typeIvar);
    metadata[@"_native_properties_type_encoding"] =
        propertiesTypeEncoding && propertiesTypeEncoding[0]
            ? ([NSString stringWithUTF8String:propertiesTypeEncoding] ?: @"")
            : @"<stripped-empty; initializer ABI q48>";
    metadata[@"_preferences_store_class"] = preferencesStore
        ? (NSStringFromClass([preferencesStore class]) ?: @"") : NSNull.null;
    metadata[@"_account_provider_class"] = accountProvider
        ? (NSStringFromClass([accountProvider class]) ?: @"") : NSNull.null;
    metadata[@"_store_user_context_class"] = storeUserContext
        ? (NSStringFromClass([storeUserContext class]) ?: @"") : NSNull.null;

    NSString *identity = [NSString stringWithFormat:@"WAPropertiesStore:%@:%ld:%@",
        storeNamespace ?: @"?", (long)propertiesType, groupJID ?: @"personal"];
    WAGRABPropsNativeSnapshot *snapshot = [WAGRABPropsNativeSnapshot new];
    snapshot.suiteName = kWAGRABPropsSharedSuite;
    snapshot.payloadKey = identity;
    snapshot.props = props;
    snapshot.metadata = metadata;
    snapshot.loadedAt = [NSDate date];
    snapshot.numericPropCount = numericCount;
    snapshot.fingerprint = WAGRABFingerprint(identity, props, metadata);
    snapshot.sourceKind = @"exact_native_wa_properties_store";
    snapshot.storeClassName = NSStringFromClass([store class]);
    snapshot.storeNamespace = storeNamespace;
    snapshot.storeGroupJID = groupJID;
    snapshot.storePropertiesType = propertiesType;
    WAGRABNativeSetDiagnostic([NSString stringWithFormat:
        @"exact store class=%@ namespace=%@ type=%ld group=%@ props=%lu fingerprint=%@",
        snapshot.storeClassName ?: @"?", storeNamespace ?: @"?", (long)propertiesType,
        groupJID ?: @"personal", (unsigned long)numericCount, snapshot.fingerprint]);
    return snapshot;
}

#pragma mark - Canonical names

NSString *WAGRABPropsDisplayNameForCode(NSString *code) {
    if (!code.length) return @"";
    NSString *native = WAGRABPropsCanonicalNameForCode(code);
    if (native.length) return native;

    NSString *legacy = nil;
    @try { legacy = WAGRWAABDisplayNameForKey(code); }
    @catch (__unused NSException *exception) { legacy = nil; }
    if (legacy.length && ![legacy isEqualToString:code] && ![legacy hasPrefix:@"ABProperty "]) return legacy;
    return [NSString stringWithFormat:@"ABProp %@", code];
}

#pragma mark - MobileConfig enrichment

static uint64_t WAGRABMCSpecifierForCode(unsigned long long code) {
    Class cls = NSClassFromString(@"WAMCEvaluation");
    SEL selector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method method = class_getClassMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABMethodWordArgument(method, 2) || !WAGRABMethodWordReturn(method)) return 0;
    @try { return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)cls, selector, code); }
    @catch (__unused NSException *exception) { return 0; }
}

static BOOL WAGRABMCBoolean(id manager, NSString *selectorName, BOOL *available) {
    if (available) *available = NO;
    if (!manager) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRABMethodReturnsInteger(method)) return NO;
    if (available) *available = YES;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(manager, selector); }
    @catch (__unused NSException *exception) { return NO; }
}

static BOOL WAGRABMCClassIsContextManagerFamily(Class cls) {
    if (!cls) return NO;
    Class base = NSClassFromString(@"FBMobileConfigContextManager") ?: objc_getClass("FBMobileConfigContextManager");
    if (base) {
        for (Class current = cls; current; current = class_getSuperclass(current)) {
            if (current == base) return YES;
        }
    }
    NSString *name = NSStringFromClass(cls) ?: @"";
    Method stable = class_getInstanceMethod(cls, NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    Method path = class_getInstanceMethod(cls, NSSelectorFromString(@"getOverridesTablePath"));
    return [name hasPrefix:@"FBMobileConfig"] && [name hasSuffix:@"ContextManager"] &&
           stable && method_getNumberOfArguments(stable) == 3 && WAGRABMethodWordArgument(stable, 2) &&
           path && method_getNumberOfArguments(path) == 2 && WAGRABMethodReturnsObject(path);
}

static BOOL WAGRABMCManagerIsUsable(id manager) {
    if (!manager || !WAGRABMCClassIsContextManagerFamily([manager class])) return NO;
    BOOL hasManagerSelector = NO, hasConfigSelector = NO;
    BOOL hasManager = WAGRABMCBoolean(manager, @"hasValidManager", &hasManagerSelector);
    BOOL hasConfig = WAGRABMCBoolean(manager, @"hasValidConfig", &hasConfigSelector);
    if (hasManagerSelector && !hasManager) return NO;
    if (hasConfigSelector && !hasConfig) return NO;
    Method stable = class_getInstanceMethod([manager class], NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    return stable && method_getNumberOfArguments(stable) == 3 && WAGRABMethodWordArgument(stable, 2);
}

static id WAGRABResolveMCManager(id userContext) {
    id manager = WAGRMobileConfigContextManager(userContext);
    if (WAGRABMCManagerIsUsable(manager)) return manager;

    Class cls = NSClassFromString(@"FBMobileConfigContextManager") ?: objc_getClass("FBMobileConfigContextManager");
    for (NSString *selectorName in @[@"sessionlessContextManager", @"defaultValueContextManager"]) {
        id candidate = WAGRABCallClassObjectNoArg(cls, selectorName);
        if (WAGRABMCManagerIsUsable(candidate)) {
            WAGRLogAppendF(@"[ABProps][MC] direct manager via +%@", selectorName);
            return candidate;
        }
    }
    return nil;
}

static uint64_t WAGRABConfigStableId(id manager, uint64_t specifier) {
    if (!WAGRABMCManagerIsUsable(manager) || !specifier) return 0;
    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3) return 0;
    @try {
        if (WAGRABMethodReturnsObject(method)) {
            id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            if ([value respondsToSelector:@selector(unsignedLongLongValue)]) return [value unsignedLongLongValue];
            return strtoull([[value description] UTF8String] ?: "0", NULL, 10);
        }
        if (WAGRABMethodReturnsInteger(method)) {
            return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
        }
    } @catch (__unused NSException *exception) {}
    return 0;
}

static NSString *WAGRABPathString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value path];
    if ([value respondsToSelector:@selector(path)]) {
        @try {
            id path = [value path];
            if ([path isKindOfClass:NSString.class]) return path;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static NSString *WAGRABMCNamesPath(id manager) {
    id pathValue = WAGRABCallObjectNoArg(manager, @"getOverridesTablePath");
    NSString *path = WAGRABPathString(pathValue);
    if (!path.length) return nil;
    NSString *directory = [[path pathExtension].lowercaseString isEqualToString:@"json"]
        ? [path stringByDeletingLastPathComponent] : path;
    return [directory stringByAppendingPathComponent:@"id_name_mapping.json"];
}

static NSDictionary *WAGRABLoadMCNames(id manager) {
    NSString *path = WAGRABMCNamesPath(manager);
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *configs = [NSMutableDictionary dictionary];
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];

    if ([object isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
            NSString *keyString = [key isKindOfClass:NSString.class] ? key : [key description];
            NSArray *keyParts = [keyString componentsSeparatedByString:@":"];
            unsigned long long configId = keyParts.count ? strtoull([keyParts[0] UTF8String] ?: "0", NULL, 10) : 0;
            if (!configId) return;
            if (keyParts.count > 1) {
                NSString *name = [keyParts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (name.length) configs[@(configId)] = name;
            }
            if (![value isKindOfClass:NSArray.class]) return;
            for (id rowObject in (NSArray *)value) {
                if (![rowObject isKindOfClass:NSString.class]) continue;
                NSArray *row = [(NSString *)rowObject componentsSeparatedByString:@":"];
                if (row.count < 2) continue;
                NSInteger parameterIndex = [row[0] integerValue];
                NSString *parameterName = [row[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (parameterName.length) {
                    parameters[[NSString stringWithFormat:@"%llu:%ld", configId, (long)parameterIndex]] = parameterName;
                }
            }
        }];
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id lineObject in (NSArray *)object) {
            if (![lineObject isKindOfClass:NSString.class]) continue;
            NSArray *parts = [(NSString *)lineObject componentsSeparatedByString:@":"];
            if (parts.count < 2) continue;
            unsigned long long configId = strtoull([parts[0] UTF8String] ?: "0", NULL, 10);
            if (!configId) continue;
            NSString *configName = [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (configName.length) configs[@(configId)] = configName;
            for (NSUInteger i = 2; i + 1 < parts.count; i += 2) {
                NSInteger parameterIndex = [parts[i] integerValue];
                NSString *parameterName = [parts[i + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (parameterName.length) {
                    parameters[[NSString stringWithFormat:@"%llu:%ld", configId, (long)parameterIndex]] = parameterName;
                }
            }
        }
    }
    return @{ @"configs": configs, @"parameters": parameters };
}

static NSString *WAGRABEmbeddedMCName(uint64_t specifier) {
    if (!specifier) return nil;
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs");
    id instance = WAGRABCallClassObjectNoArg(cls, @"getInstance");
    if (!instance) return nil;
    SEL selector = NSSelectorFromString(@"convertSpecifierToParamName:");
    Method method = class_getInstanceMethod([instance class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 ||
        !WAGRABMethodReturnsObject(method) || !WAGRABMethodWordArgument(method, 2)) return nil;
    @try {
        id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(instance, selector, specifier);
        return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static void WAGRABSplitEmbeddedMCName(NSString *fullName, NSString **configName, NSString **parameterName) {
    if (configName) *configName = nil;
    if (parameterName) *parameterName = nil;
    if (!fullName.length) return;
    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0 && NSMaxRange(dot) < fullName.length) {
        if (configName) *configName = [fullName substringToIndex:dot.location];
        if (parameterName) *parameterName = [fullName substringFromIndex:NSMaxRange(dot)];
    } else if (parameterName) {
        *parameterName = fullName;
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


NSDictionary<NSString *, id> *WAGRABPropsNativeABTOnlyExportDocument(
    WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{};
    NSArray *sortedKeys = [snapshot.props.allKeys sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        unsigned long long a = [[left description] longLongValue];
        unsigned long long b = [[right description] longLongValue];
        if (a < b) return NSOrderedAscending;
        if (a > b) return NSOrderedDescending;
        return [[left description] compare:[right description]];
    }];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:sortedKeys.count];
    NSUInteger canonicalNamed = 0;
    for (id keyObject in sortedKeys) {
        NSString *code = [keyObject description];
        if (!WAGRABStringIsDecimal(code)) continue;
        id rawEntry = snapshot.props[keyObject];
        NSDictionary *entryDictionary = [rawEntry isKindOfClass:NSDictionary.class]
            ? rawEntry : @{};
        id wireValue = entryDictionary[@"value"] ?: rawEntry ?: NSNull.null;
        NSString *displayName = WAGRABPropsDisplayNameForCode(code);
        if (displayName.length && ![displayName hasPrefix:@"ABProp "]) canonicalNamed++;
        NSMutableDictionary *entry = [@{
            @"code": @([code longLongValue]),
            @"name": displayName ?: [NSString stringWithFormat:@"ABProp %@", code],
            @"value": WAGRABJSONSafe(wireValue),
            @"native_entry": WAGRABJSONSafe(rawEntry),
        } mutableCopy];
        if (entryDictionary[@"expoKey"]) entry[@"expoKey"] = WAGRABJSONSafe(entryDictionary[@"expoKey"]);
        [entries addObject:entry];
    }
    return @{
        @"format": @"WATweaks WhatsApp native ABProps ABT snapshot v1",
        @"scope": @"ABT only; MobileConfig intentionally excluded",
        @"source_kind": snapshot.sourceKind ?: @"unknown",
        @"source": @"WAProperties._propertiesStore.properties; native App Group-backed preferences store",
        @"suite": snapshot.suiteName ?: kWAGRABPropsSharedSuite,
        @"native_store": @{
            @"class": snapshot.storeClassName ?: NSNull.null,
            @"namespace": snapshot.storeNamespace ?: NSNull.null,
            @"group_jid": snapshot.storeGroupJID ?: NSNull.null,
            @"properties_type": @(snapshot.storePropertiesType),
            @"layout_evidence": @{
                @"WAProperties._propertiesStore": @8,
                @"WAPropertiesStore.preferencesStore": @8,
                @"WAPropertiesStore.namespace": @32,
                @"WAPropertiesStore.propertiesType": @48,
                @"WAPropertiesStore.groupJID": @56,
                @"WAPropertiesStore.properties": @96,
            }
        },
        @"store_identity": snapshot.payloadKey ?: @"",
        @"prop_count": @(entries.count),
        @"fingerprint": snapshot.fingerprint ?: @"",
        @"loaded_at": snapshot.loadedAt.description ?: @"",
        @"metadata": WAGRABJSONSafe(snapshot.metadata ?: @{}),
        @"canonical_abprop_names": @(canonicalNamed),
        @"canonical_catalog_size": @(WAGRABPropsCanonicalNameCount()),
        @"entries": entries,
    };
}

NSDictionary<NSString *, id> *WAGRABPropsNativeExportDocument(WAGRABPropsNativeSnapshot *snapshot) {
    if (!snapshot) return @{};
    id context = WAGRCurrentUserContext();
    id manager = WAGRABResolveMCManager(context);
    NSDictionary *names = manager ? WAGRABLoadMCNames(manager) : @{};
    NSDictionary *configNames = names[@"configs"] ?: @{};
    NSDictionary *parameterNames = names[@"parameters"] ?: @{};

    NSArray *sortedKeys = [snapshot.props.allKeys sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        unsigned long long a = [[left description] longLongValue];
        unsigned long long b = [[right description] longLongValue];
        if (a < b) return NSOrderedAscending;
        if (a > b) return NSOrderedDescending;
        return [[left description] compare:[right description]];
    }];

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:sortedKeys.count];
    NSUInteger translated = 0;
    NSUInteger configResolved = 0;
    NSUInteger canonicalNamed = 0;

    for (id keyObject in sortedKeys) {
        NSString *code = [keyObject description];
        if (!WAGRABStringIsDecimal(code)) continue;
        id rawEntry = snapshot.props[keyObject];
        NSDictionary *entryDictionary = [rawEntry isKindOfClass:NSDictionary.class] ? rawEntry : @{};
        id wireValue = entryDictionary[@"value"] ?: rawEntry ?: NSNull.null;
        NSString *displayName = WAGRABPropsDisplayNameForCode(code);
        if (displayName.length && ![displayName hasPrefix:@"ABProp "]) canonicalNamed++;

        NSMutableDictionary *entry = [@{
            @"code" : @([code longLongValue]),
            @"name" : displayName ?: [NSString stringWithFormat:@"ABProp %@", code],
            @"value" : WAGRABJSONSafe(wireValue),
            @"native_entry" : WAGRABJSONSafe(rawEntry),
        } mutableCopy];
        if (entryDictionary[@"expoKey"]) entry[@"expoKey"] = WAGRABJSONSafe(entryDictionary[@"expoKey"]);

        uint64_t specifier = WAGRABMCSpecifierForCode(strtoull(code.UTF8String ?: "0", NULL, 10));
        if (specifier && !(specifier & (1ULL << 62))) {
            translated++;
            uint16_t parameterIndex = (uint16_t)((specifier >> 16) & 0xFFFF);
            NSMutableDictionary *mc = [@{
                @"param_specifier_hex" : [NSString stringWithFormat:@"0x%016llx", specifier],
                @"local_config_index" : @((specifier >> 32) & 0xFFFF),
                @"parameter_index" : @(parameterIndex),
                @"compact_parameter_token" : @(specifier & 0xFFFF),
                @"native_type" : @((specifier >> 48) & 0x3F),
            } mutableCopy];

            uint64_t configStableId = WAGRABConfigStableId(manager, specifier);
            if (configStableId) {
                configResolved++;
                mc[@"config_stable_id"] = @(configStableId);
                NSString *configName = configNames[@(configStableId)];
                NSString *parameterName = parameterNames[[NSString stringWithFormat:@"%llu:%u", configStableId, parameterIndex]];
                if (!configName.length || !parameterName.length) {
                    NSString *embedded = WAGRABEmbeddedMCName(specifier);
                    NSString *embeddedConfig = nil, *embeddedParameter = nil;
                    WAGRABSplitEmbeddedMCName(embedded, &embeddedConfig, &embeddedParameter);
                    if (!configName.length) configName = embeddedConfig;
                    if (!parameterName.length) parameterName = embeddedParameter;
                }
                if (configName.length) mc[@"config_name"] = configName;
                if (parameterName.length) mc[@"parameter_name"] = parameterName;
            }
            entry[@"mobileconfig"] = mc;
        }
        [entries addObject:entry];
    }

    return @{
        @"format" : @"WATweaks WhatsApp native ABProps snapshot v3",
        @"source" : @"group.net.whatsapp.WhatsApp.shared / account-scoped gabp.*p",
        @"suite" : snapshot.suiteName ?: kWAGRABPropsSharedSuite,
        @"payload_key" : snapshot.payloadKey ?: @"",
        @"metadata_key" : snapshot.metadataKey ?: NSNull.null,
        @"prop_count" : @(snapshot.numericPropCount),
        @"fingerprint" : snapshot.fingerprint ?: @"",
        @"loaded_at" : snapshot.loadedAt.description ?: @"",
        @"metadata" : WAGRABJSONSafe(snapshot.metadata ?: @{}),
        @"mobileconfig_resolution" : @{
            @"manager_resolved" : @(manager != nil),
            @"translated" : @(translated),
            @"config_stable_ids_resolved" : @(configResolved),
            @"canonical_abprop_names" : @(canonicalNamed),
            @"canonical_catalog_size" : @(WAGRABPropsCanonicalNameCount()),
            @"semantic_note" : @"config_stable_id + parameter_index identify mc_overrides; compact_parameter_token is low-16 translation metadata; names are optional"
        },
        @"entries" : entries,
    };
}
