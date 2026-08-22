#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern id WAGRCurrentUserContext(void);

static const NSUInteger kWAGRValidatedWAStableIdCount = 34666;
static NSString * const kWAGRMCErrorDomain = @"WATweaks.MobileConfig";

@implementation WAGRMobileConfigMapping
- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [@{
        @"wa_stable_id" : @(self.waStableId),
        @"param_specifier_hex" : [NSString stringWithFormat:@"0x%016llx", self.paramSpecifier],
        @"local_config_index" : @(self.localConfigIndex),
        @"parameter_index" : @(self.parameterIndex),
        @"compact_parameter_token" : @(self.parameterStableId),
        @"native_type" : @(self.nativeType),
        @"native_type_name" : (self.nativeType == 1 ? @"bool" :
                                self.nativeType == 2 ? @"int64" :
                                self.nativeType == 3 ? @"string" :
                                self.nativeType == 4 ? @"double" : @"unknown"),
        @"external_config_stable_id" : @(self.externalConfigStableId),
    } mutableCopy];
    if (self.configName.length) dictionary[@"config_name"] = self.configName;
    if (self.parameterName.length) dictionary[@"parameter_name"] = self.parameterName;
    return dictionary;
}
@end

#pragma mark - Runtime validation helpers

static const char *WAGRMCSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCMethodArgumentFitsWord(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[128] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRMCSkipQualifiers(raw);
    if (!*type) return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRMCMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRMCMethodReturnsInteger(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRMCSkipQualifiers(raw)[0]) {
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
            return YES;
        default:
            return NO;
    }
}

static BOOL WAGRMCMethodReturnsWord(Method method) {
    if (!method) return NO;
    char raw[128] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRMCSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRMCMethodReturnsDouble(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCSkipQualifiers(raw)[0] == 'd';
}

static BOOL WAGRMCMethodReturnsFloat(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCSkipQualifiers(raw)[0] == 'f';
}

static BOOL WAGRMCMethodIsObjectNoArg(Method method) {
    return method && method_getNumberOfArguments(method) == 2 && WAGRMCMethodReturnsObject(method);
}

static BOOL WAGRMCMethodIsWordToWord(Method method) {
    return method && method_getNumberOfArguments(method) == 3 &&
           WAGRMCMethodReturnsWord(method) && WAGRMCMethodArgumentFitsWord(method, 2);
}

static id WAGRMCCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!WAGRMCMethodIsObjectNoArg(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRMCCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!WAGRMCMethodIsObjectNoArg(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static uint64_t WAGRMCClassIntegerReturnValue(Class cls, SEL selector, uint64_t argument) {
    if (!cls || !selector) return 0;
    Method method = class_getClassMethod(cls, selector);
    if (!WAGRMCMethodIsWordToWord(method)) return 0;
    @try { return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)cls, selector, argument); }
    @catch (__unused NSException *exception) { return 0; }
}

#pragma mark - Live context-manager resolution

static id gWAGRMCContextManager = nil;
static NSString *gWAGRMCContextManagerSource = nil;
static NSObject *gWAGRMCLock = nil;
static BOOL gWAGRMCPathHooked = NO;
static BOOL gWAGRMCBoolHooked = NO;
static id (*orig_WAGRMCGetOverridesTablePath)(id, SEL) = NULL;
static BOOL (*orig_WAGRMCGetBool)(id, SEL, uint64_t) = NULL;

static void WAGRMCEnsureLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWAGRMCLock = [NSObject new]; });
}

static BOOL WAGRMCClassDescendsFromContextManager(Class cls) {
    if (!cls) return NO;
    Class base = NSClassFromString(@"FBMobileConfigContextManager") ?: objc_getClass("FBMobileConfigContextManager");
    if (base) {
        for (Class current = cls; current; current = class_getSuperclass(current)) {
            if (current == base) return YES;
        }
    }
    return NO;
}

static BOOL WAGRMCClassHasContextManagerABI(Class cls) {
    if (!cls) return NO;
    Method stable = class_getInstanceMethod(cls, NSSelectorFromString(@"getStableIdFromParamSpecifier:"));
    Method path = class_getInstanceMethod(cls, NSSelectorFromString(@"getOverridesTablePath"));
    return stable && method_getNumberOfArguments(stable) == 3 &&
           WAGRMCMethodArgumentFitsWord(stable, 2) &&
           WAGRMCMethodIsObjectNoArg(path);
}

static BOOL WAGRMCObjectIsContextManager(id object) {
    if (!object) return NO;
    Class cls = [object class];

    // The supplied SharedModules Mach-O proves that
    // FBMobileConfigUserSessionContextManager subclasses FBMobileConfigContextManager.
    // The old substring test rejected it because "UserSession" sits between
    // "FBMobileConfig" and "ContextManager" in the concrete class name.
    if (WAGRMCClassDescendsFromContextManager(cls)) return YES;

    NSString *name = NSStringFromClass(cls) ?: @"";
    if ([name hasPrefix:@"FBMobileConfig"] && [name hasSuffix:@"ContextManager"] &&
        WAGRMCClassHasContextManagerABI(cls)) return YES;
    return NO;
}

static void WAGRMCRememberManager(id manager, NSString *source) {
    if (!WAGRMCObjectIsContextManager(manager)) return;
    WAGRMCEnsureLock();
    @synchronized (gWAGRMCLock) {
        if (gWAGRMCContextManager == manager && [gWAGRMCContextManagerSource isEqualToString:source]) return;
        gWAGRMCContextManager = manager;
        gWAGRMCContextManagerSource = [source copy] ?: @"unknown";
    }
    WAGRLogAppendF(@"[MobileConfig] captured %@ from %@",
                   NSStringFromClass([manager class]) ?: @"?", source ?: @"unknown");
}

static id hook_WAGRMCGetOverridesTablePath(id self, SEL _cmd) {
    WAGRMCRememberManager(self, @"getOverridesTablePath");
    return orig_WAGRMCGetOverridesTablePath ? orig_WAGRMCGetOverridesTablePath(self, _cmd) : nil;
}

static BOOL hook_WAGRMCGetBool(id self, SEL _cmd, uint64_t parameter) {
    WAGRMCRememberManager(self, @"getBool:");
    return orig_WAGRMCGetBool ? orig_WAGRMCGetBool(self, _cmd, parameter) : NO;
}

void WAGRMobileConfigEnsureCaptureHooksInstalled(void) {
    Class base = NSClassFromString(@"FBMobileConfigContextManager") ?: objc_getClass("FBMobileConfigContextManager");
    if (!base) return;

    if (!gWAGRMCPathHooked) {
        SEL selector = NSSelectorFromString(@"getOverridesTablePath");
        Method method = class_getInstanceMethod(base, selector);
        if (WAGRMCMethodIsObjectNoArg(method)) {
            MSHookMessageEx(base, selector, (IMP)hook_WAGRMCGetOverridesTablePath,
                            (IMP *)&orig_WAGRMCGetOverridesTablePath);
            gWAGRMCPathHooked = (orig_WAGRMCGetOverridesTablePath != NULL);
        }
    }

    if (!gWAGRMCBoolHooked) {
        SEL selector = NSSelectorFromString(@"getBool:");
        Method method = class_getInstanceMethod(base, selector);
        if (method && method_getNumberOfArguments(method) == 3 &&
            WAGRMCMethodReturnsInteger(method) && WAGRMCMethodArgumentFitsWord(method, 2)) {
            MSHookMessageEx(base, selector, (IMP)hook_WAGRMCGetBool,
                            (IMP *)&orig_WAGRMCGetBool);
            gWAGRMCBoolHooked = (orig_WAGRMCGetBool != NULL);
        }
    }
}

static id WAGRMCProbeObjectGraph(id root,
                                  NSMutableSet<NSValue *> *visited,
                                  NSUInteger depth) {
    if (!root || depth > 4) return nil;
    if (WAGRMCObjectIsContextManager(root)) return root;

    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    NSArray<NSString *> *selectors = @[
        @"mobileConfig", @"mobileConfigContextManager", @"mobileConfigManager",
        @"mcContextManager", @"contextManager", @"configManager",
        @"userContext", @"mainContext", @"sharedContext"
    ];
    for (NSString *selectorName in selectors) {
        id child = WAGRMCCallObjectNoArg(root, selectorName);
        if (!child || child == root) continue;
        id found = WAGRMCProbeObjectGraph(child, visited, depth + 1);
        if (found) return found;
    }

    for (Class current = [root class]; current && current != NSObject.class;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *nameCString = ivar_getName(ivar);
            const char *typeCString = ivar_getTypeEncoding(ivar);
            if (!nameCString || !typeCString || WAGRMCSkipQualifiers(typeCString)[0] != '@') continue;
            NSString *name = [[NSString stringWithUTF8String:nameCString] lowercaseString] ?: @"";
            BOOL interesting = [name containsString:@"mobileconfig"] ||
                               [name containsString:@"configmanager"] ||
                               [name containsString:@"contextmanager"] ||
                               [name containsString:@"mcmanager"];
            if (!interesting) continue;
            id child = nil;
            @try { child = object_getIvar(root, ivar); }
            @catch (__unused NSException *exception) { child = nil; }
            id found = WAGRMCProbeObjectGraph(child, visited, depth + 1);
            if (found) { free(ivars); return found; }
        }
        free(ivars);
    }
    return nil;
}

id WAGRMobileConfigContextManager(id userContext) {
    WAGRMobileConfigEnsureCaptureHooksInstalled();
    WAGRMCEnsureLock();
    @synchronized (gWAGRMCLock) {
        if (WAGRMCObjectIsContextManager(gWAGRMCContextManager)) return gWAGRMCContextManager;
    }

    id context = userContext ?: WAGRCurrentUserContext();

    // Fast path proven by the live log supplied from this build:
    // WAContextMain.mobileConfig -> FBMobileConfigUserSessionContextManager.
    id direct = WAGRMCCallObjectNoArg(context, @"mobileConfig");
    if (WAGRMCObjectIsContextManager(direct)) {
        WAGRMCRememberManager(direct, @"userContext.mobileConfig");
        return direct;
    }

    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    id manager = WAGRMCProbeObjectGraph(context, visited, 0);
    if (manager) {
        WAGRMCRememberManager(manager, @"userContext graph");
        return manager;
    }

    Class base = NSClassFromString(@"FBMobileConfigContextManager") ?: objc_getClass("FBMobileConfigContextManager");
    for (NSString *selectorName in @[@"sessionlessContextManager", @"defaultValueContextManager"]) {
        id candidate = WAGRMCCallClassObjectNoArg(base, selectorName);
        if (!WAGRMCObjectIsContextManager(candidate)) continue;
        WAGRMCRememberManager(candidate, [@"+FBMobileConfigContextManager." stringByAppendingString:selectorName]);
        return candidate;
    }
    return nil;
}

#pragma mark - Paths and canonical names

static NSString *WAGRMCPathString(id value) {
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

NSString *WAGRMobileConfigOverridesPath(id userContext) {
    id manager = WAGRMobileConfigContextManager(userContext);
    if (!manager) return nil;
    id pathValue = WAGRMCCallObjectNoArg(manager, @"getOverridesTablePath");
    NSString *path = WAGRMCPathString(pathValue);
    if (!path.length) return nil;
    if ([[path pathExtension].lowercaseString isEqualToString:@"json"]) return path;
    return [path stringByAppendingPathComponent:@"mc_overrides.json"];
}

NSString *WAGRMobileConfigNamesPath(id userContext) {
    NSString *overrides = WAGRMobileConfigOverridesPath(userContext);
    if (!overrides.length) return nil;
    return [[overrides stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"id_name_mapping.json"];
}

static NSDictionary *WAGRMCLoadCanonicalNames(NSString *path) {
    if (!path.length) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSMutableDictionary *configNames = [NSMutableDictionary dictionary];
    NSMutableDictionary *parameterNames = [NSMutableDictionary dictionary];

    void (^consumeLine)(NSString *) = ^(NSString *line) {
        if (![line isKindOfClass:NSString.class] || !line.length) return;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@":"];
        if (parts.count < 2) return;
        unsigned long long configId = strtoull(parts[0].UTF8String ?: "0", NULL, 10);
        if (!configId) return;
        NSString *configName = parts[1];
        if (configName.length) configNames[@(configId)] = configName;
        for (NSUInteger index = 2; index + 1 < parts.count; index += 2) {
            NSInteger parameterIndex = [parts[index] integerValue];
            NSString *parameterName = parts[index + 1];
            if (!parameterName.length) continue;
            parameterNames[[NSString stringWithFormat:@"%llu:%ld",
                            configId, (long)parameterIndex]] = parameterName;
        }
    };

    if ([object isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)object) if ([item isKindOfClass:NSString.class]) consumeLine(item);
    } else if ([object isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:NSString.class]) return;
            NSArray<NSString *> *keyParts = [(NSString *)key componentsSeparatedByString:@":"];
            if (!keyParts.count) return;
            unsigned long long configId = strtoull(keyParts[0].UTF8String ?: "0", NULL, 10);
            if (!configId) return;
            if (keyParts.count > 1 && keyParts[1].length) configNames[@(configId)] = keyParts[1];
            if (![value isKindOfClass:NSArray.class]) return;
            for (id rowObject in (NSArray *)value) {
                if (![rowObject isKindOfClass:NSString.class]) continue;
                NSArray<NSString *> *rowParts = [(NSString *)rowObject componentsSeparatedByString:@":"];
                if (rowParts.count < 2) continue;
                NSInteger parameterIndex = [rowParts[0] integerValue];
                NSString *parameterName = [rowParts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (parameterName.length) {
                    parameterNames[[NSString stringWithFormat:@"%llu:%ld", configId, (long)parameterIndex]] = parameterName;
                }
            }
        }];
    }
    return @{ @"configs" : configNames, @"parameters" : parameterNames };
}

#pragma mark - Mapping

static NSUInteger WAGRMCStableIdDomainCount(Class evaluationClass) {
    NSArray<NSString *> *countSelectors = @[
        @"getWAStableIdToParamSpecifierEntriesCount",
        @"getWAStableIdToParamSpecifierEntriesSize",
        @"waStableIdToParamSpecifierEntryCount",
        @"waStableIdToParamSpecifierEntriesCount"
    ];
    for (NSString *selectorName in countSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getClassMethod(evaluationClass, selector);
        if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMCMethodReturnsInteger(method)) continue;
        @try {
            uint64_t count = ((uint64_t (*)(id, SEL))objc_msgSend)((id)evaluationClass, selector);
            if (count > 0 && count <= UINT16_MAX + 1ULL) return (NSUInteger)count;
        } @catch (__unused NSException *exception) {}
    }

    SEL entriesSelector = NSSelectorFromString(@"getWAStableIdToParamSpecifierEntries");
    Method entriesMethod = class_getClassMethod(evaluationClass, entriesSelector);
    if (WAGRMCMethodIsObjectNoArg(entriesMethod)) {
        @try {
            id entries = ((id (*)(id, SEL))objc_msgSend)((id)evaluationClass, entriesSelector);
            if ([entries respondsToSelector:@selector(count)]) {
                NSUInteger count = [entries count];
                if (count > 0 && count <= UINT16_MAX + 1ULL) return count;
            }
        } @catch (__unused NSException *exception) {}
    }
    return kWAGRValidatedWAStableIdCount;
}

static uint64_t WAGRMCExternalStableId(id manager, uint64_t specifier) {
    if (!manager || !specifier) return 0;
    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRMCMethodArgumentFitsWord(method, 2)) return 0;

    @try {
        if (WAGRMCMethodReturnsObject(method)) {
            id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            if ([value respondsToSelector:@selector(unsignedLongLongValue)]) return [value unsignedLongLongValue];
            return strtoull([[value description] UTF8String] ?: "0", NULL, 10);
        }
        if (WAGRMCMethodReturnsInteger(method)) {
            return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
        }
    } @catch (__unused NSException *exception) {}
    return 0;
}

NSArray<WAGRMobileConfigMapping *> *WAGRMobileConfigResolveAll(
    id userContext,
    WAGRMobileConfigProgressBlock progress,
    NSError **outError) {

    id manager = WAGRMobileConfigContextManager(userContext);
    if (!manager) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWAGRMCErrorDomain code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Nenhum FBMobileConfig *ContextManager válido foi resolvido a partir do userContext atual."}];
        }
        return nil;
    }

    Class evaluationClass = NSClassFromString(@"WAMCEvaluation");
    SEL specifierSelector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method specifierMethod = class_getClassMethod(evaluationClass, specifierSelector);
    if (!evaluationClass || !WAGRMCMethodIsWordToWord(specifierMethod)) {
        if (outError) {
            *outError = [NSError errorWithDomain:kWAGRMCErrorDomain code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    @"WAMCEvaluation.getMCSpecifierForStableId: não está disponível com ABI compatível."}];
        }
        return nil;
    }

    NSUInteger total = WAGRMCStableIdDomainCount(evaluationClass);
    NSDictionary *names = WAGRMCLoadCanonicalNames(WAGRMobileConfigNamesPath(userContext));
    NSDictionary *configNames = names[@"configs"] ?: @{};
    NSDictionary *parameterNames = names[@"parameters"] ?: @{};
    NSMutableArray<WAGRMobileConfigMapping *> *mappings = [NSMutableArray array];
    NSUInteger resolved = 0;

    for (NSUInteger stableId = 0; stableId < total; stableId++) {
        @autoreleasepool {
            uint64_t specifier = WAGRMCClassIntegerReturnValue(evaluationClass, specifierSelector, (uint64_t)stableId);
            if (!specifier || (specifier & (1ULL << 62))) {
                if (progress && ((stableId & 0xFF) == 0 || stableId + 1 == total)) {
                    progress(stableId + 1, total, mappings.count, resolved);
                }
                continue;
            }

            WAGRMobileConfigMapping *mapping = [WAGRMobileConfigMapping new];
            mapping.waStableId = stableId;
            mapping.paramSpecifier = specifier;
            mapping.localConfigIndex = (uint16_t)((specifier >> 32) & 0xFFFF);
            mapping.parameterIndex = (uint16_t)((specifier >> 16) & 0xFFFF);
            mapping.parameterStableId = (uint16_t)(specifier & 0xFFFF);
            mapping.nativeType = (uint8_t)((specifier >> 48) & 0x3F);
            mapping.externalConfigStableId = WAGRMCExternalStableId(manager, specifier);
            if (mapping.externalConfigStableId) {
                resolved++;
                mapping.configName = configNames[@(mapping.externalConfigStableId)];
                mapping.parameterName = parameterNames[[NSString stringWithFormat:@"%llu:%u",
                    mapping.externalConfigStableId, mapping.parameterIndex]];
            }
            [mappings addObject:mapping];

            if (progress && ((stableId & 0xFF) == 0 || stableId + 1 == total)) {
                progress(stableId + 1, total, mappings.count, resolved);
            }
        }
    }

    WAGRLogAppendF(@"[MobileConfig] scan manager=%@ domain=%lu translated=%lu externalResolved=%lu names=%lu",
                   NSStringFromClass([manager class]) ?: @"?",
                   (unsigned long)total,
                   (unsigned long)mappings.count,
                   (unsigned long)resolved,
                   (unsigned long)configNames.count);
    return mappings;
}

#pragma mark - Native typed reads and export

id WAGRMobileConfigCurrentValue(WAGRMobileConfigMapping *mapping, id userContext) {
    if (!mapping || !mapping.paramSpecifier) return nil;
    id manager = WAGRMobileConfigContextManager(userContext);
    if (!manager) return nil;

    NSString *selectorName = nil;
    switch (mapping.nativeType) {
        case 1: selectorName = @"getBool:"; break;
        case 2: selectorName = @"getInt64:"; break;
        case 3: selectorName = @"getString:"; break;
        case 4: selectorName = @"getDouble:"; break;
        default: return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3 || !WAGRMCMethodArgumentFitsWord(method, 2)) return nil;

    @try {
        switch (mapping.nativeType) {
            case 1:
                if (!WAGRMCMethodReturnsInteger(method)) return nil;
                return @(((BOOL (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, mapping.paramSpecifier));
            case 2:
                if (!WAGRMCMethodReturnsInteger(method)) return nil;
                return @(((long long (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, mapping.paramSpecifier));
            case 3:
                if (!WAGRMCMethodReturnsObject(method)) return nil;
                return ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, mapping.paramSpecifier);
            case 4:
                if (WAGRMCMethodReturnsDouble(method)) {
                    return @(((double (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, mapping.paramSpecifier));
                }
                if (WAGRMCMethodReturnsFloat(method)) {
                    return @(((float (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, mapping.paramSpecifier));
                }
                return nil;
            default:
                return nil;
        }
    } @catch (__unused NSException *exception) { return nil; }
}

static NSString *WAGRMCISO8601Now(void) {
    if (@available(iOS 10.0, *)) {
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        return [formatter stringFromDate:[NSDate date]] ?: @"";
    }
    return [[NSDate date] description];
}

NSDictionary<NSString *, id> *WAGRMobileConfigCrosswalkDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id userContext) {
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:mappings.count];
    NSUInteger resolved = 0, named = 0;
    for (WAGRMobileConfigMapping *mapping in mappings) {
        [entries addObject:[mapping dictionaryRepresentation]];
        if (mapping.externalConfigStableId) resolved++;
        if (mapping.configName.length || mapping.parameterName.length) named++;
    }
    NSString *overridesPath = WAGRMobileConfigOverridesPath(userContext);
    NSString *namesPath = WAGRMobileConfigNamesPath(userContext);
    return @{
        @"format" : @"WATweaks WhatsApp ABProp -> FBMobileConfig live crosswalk",
        @"generated_at" : WAGRMCISO8601Now(),
        @"source" : @"WAMCEvaluation + live FBMobileConfig *ContextManager",
        @"manager_class" : WAGRMobileConfigContextManager(userContext)
            ? NSStringFromClass([WAGRMobileConfigContextManager(userContext) class]) : NSNull.null,
        @"scan" : @{
            @"translated" : @(mappings.count),
            @"external_ids_resolved" : @(resolved),
            @"with_canonical_names" : @(named),
        },
        @"paths" : @{
            @"mc_overrides" : overridesPath ?: NSNull.null,
            @"id_name_mapping" : namesPath ?: NSNull.null,
        },
        @"entries" : entries,
    };
}

static NSString *WAGRMCOverrideValueString(id value, uint8_t nativeType) {
    if (!value || value == NSNull.null) return nil;
    if (nativeType == 1) return [value boolValue] ? @"true" : @"false";
    if (nativeType == 2) return [NSString stringWithFormat:@"%lld", [value longLongValue]];
    if (nativeType == 4) return [NSString stringWithFormat:@"%.17g", [value doubleValue]];
    if (nativeType == 3) return [value isKindOfClass:NSString.class] ? value : [value description];
    return nil;
}

NSDictionary<NSString *, id> *WAGRMobileConfigOverrideDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id userContext,
    WAGRMobileConfigOverrideExportMode mode,
    NSDictionary<NSString *, id> **stats) {

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *result = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seenParameters = [NSMutableSet set];
    NSUInteger emitted = 0, skippedUnresolved = 0, skippedUnsupported = 0, deduplicated = 0;

    for (WAGRMobileConfigMapping *mapping in mappings) {
        if (!mapping.externalConfigStableId) { skippedUnresolved++; continue; }
        if (mode == WAGRMobileConfigOverrideExportModeAllBooleansTrue && mapping.nativeType != 1) continue;
        if (mapping.nativeType < 1 || mapping.nativeType > 4) { skippedUnsupported++; continue; }

        NSString *parameterUID = [NSString stringWithFormat:@"%llu:%u",
            mapping.externalConfigStableId, mapping.parameterIndex];
        if ([seenParameters containsObject:parameterUID]) { deduplicated++; continue; }

        id currentValue = mode == WAGRMobileConfigOverrideExportModeAllBooleansTrue
            ? @YES : WAGRMobileConfigCurrentValue(mapping, userContext);
        NSString *valueString = WAGRMCOverrideValueString(currentValue, mapping.nativeType);
        if (!valueString.length) { skippedUnsupported++; continue; }

        [seenParameters addObject:parameterUID];
        NSString *configKey = mapping.configName.length
            ? [NSString stringWithFormat:@"%llu:%@", mapping.externalConfigStableId, mapping.configName]
            : [NSString stringWithFormat:@"%llu:", mapping.externalConfigStableId];
        NSString *row = mapping.parameterName.length
            ? [NSString stringWithFormat:@"%u: %@: %@", mapping.parameterIndex, mapping.parameterName, valueString]
            : [NSString stringWithFormat:@"%u: : %@", mapping.parameterIndex, valueString];
        NSMutableArray *rows = result[configKey];
        if (!rows) { rows = [NSMutableArray array]; result[configKey] = rows; }
        [rows addObject:row];
        emitted++;
    }

    [result enumerateKeysAndObjectsUsingBlock:^(__unused NSString *key, NSMutableArray<NSString *> *rows, __unused BOOL *stop) {
        [rows sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            NSInteger a = [[[left componentsSeparatedByString:@":"] firstObject] integerValue];
            NSInteger b = [[[right componentsSeparatedByString:@":"] firstObject] integerValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return [left compare:right];
        }];
    }];

    if (stats) {
        *stats = @{
            @"emitted" : @(emitted),
            @"configs" : @(result.count),
            @"skipped_unresolved_external_id" : @(skippedUnresolved),
            @"skipped_unsupported_or_unreadable" : @(skippedUnsupported),
            @"deduplicated" : @(deduplicated),
            @"mode" : mode == WAGRMobileConfigOverrideExportModeAllBooleansTrue
                ? @"all_booleans_true" : @"current_snapshot",
        };
    }
    return result;
}

NSData *WAGRMobileConfigJSONData(id object, NSError **outError) {
    if (!object) return nil;
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    return [NSJSONSerialization dataWithJSONObject:object options:options error:outError];
}

NSString *WAGRMobileConfigDiagnosticText(void) {
    WAGRMCEnsureLock();
    id manager = nil;
    NSString *source = nil;
    @synchronized (gWAGRMCLock) {
        manager = gWAGRMCContextManager;
        source = [gWAGRMCContextManagerSource copy];
    }
    id live = manager ?: WAGRMobileConfigContextManager(nil);
    return [NSString stringWithFormat:
        @"manager=%@\nsource=%@\nfamilyValid=%@\npathHook=%@\nboolHook=%@\noverridesPath=%@\nnamesPath=%@\nvalidatedStableIdDomain=%lu",
        live ? NSStringFromClass([live class]) : @"nil",
        source ?: @"none",
        WAGRMCObjectIsContextManager(live) ? @"YES" : @"NO",
        gWAGRMCPathHooked ? @"YES" : @"NO",
        gWAGRMCBoolHooked ? @"YES" : @"NO",
        WAGRMobileConfigOverridesPath(nil) ?: @"unresolved",
        WAGRMobileConfigNamesPath(nil) ?: @"unresolved",
        (unsigned long)kWAGRValidatedWAStableIdCount];
}

__attribute__((constructor))
static void WAGRMobileConfigBridgeCtor(void) {
    @autoreleasepool { WAGRMobileConfigEnsureCaptureHooksInstalled(); }
}
