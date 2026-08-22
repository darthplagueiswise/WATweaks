#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#import "WAGRABPropsNativeStore.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

#pragma mark - Shared ABI helpers

static const char *WAGRDF2SkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRDF2MethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRDF2SkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRDF2MethodReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRDF2SkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRDF2ArgumentIsObject(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    return WAGRDF2SkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRDF2ArgumentIsBool(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    char t = WAGRDF2SkipQualifiers(raw)[0];
    return t == 'B' || t == 'c' || t == 'C';
}

static id WAGRDF2CallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRDF2MethodReturnsObject(method)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

#pragma mark - 1. Exact native ABProps request manager capture/fetch

static NSObject *gWAGRDF2RequestLock = nil;
static id gWAGRDF2RequestManager = nil;
static BOOL gWAGRDF2RequestHooksInstalled = NO;
static void (*orig_WAGRDF2RequestFresh)(id, SEL, BOOL, id) = NULL;
static void (*orig_WAGRDF2RequestFreshGroup)(id, SEL, id, BOOL, id) = NULL;

static void WAGRDF2EnsureRequestLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWAGRDF2RequestLock = [NSObject new]; });
}

static BOOL WAGRDF2ObjectCanFreshFetch(id object) {
    if (!object) return NO;
    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([object class], selector);
    return method && method_getNumberOfArguments(method) == 4 &&
           WAGRDF2MethodReturnsVoid(method) &&
           WAGRDF2ArgumentIsBool(method, 2) &&
           WAGRDF2ArgumentIsObject(method, 3);
}

static void WAGRDF2RememberRequestManager(id manager, NSString *source) {
    if (!WAGRDF2ObjectCanFreshFetch(manager)) return;
    WAGRDF2EnsureRequestLock();
    @synchronized (gWAGRDF2RequestLock) {
        gWAGRDF2RequestManager = manager;
    }
    WAGRLogAppendF(@"[ABProps][FetchV2] captured %@ via %@",
                   NSStringFromClass([manager class]) ?: @"?", source ?: @"unknown");
}

static void hook_WAGRDF2RequestFresh(id self, SEL _cmd, BOOL deltaUpdate, id completion) {
    WAGRDF2RememberRequestManager(self, @"requestFreshABProps:withCompletion:");
    if (orig_WAGRDF2RequestFresh) orig_WAGRDF2RequestFresh(self, _cmd, deltaUpdate, completion);
}

static void hook_WAGRDF2RequestFreshGroup(id self, SEL _cmd, id groupJID, BOOL deltaUpdate, id completion) {
    WAGRDF2RememberRequestManager(self, @"requestFreshABPropsWithGroupJID:deltaUpdate:completion:");
    if (orig_WAGRDF2RequestFreshGroup) {
        orig_WAGRDF2RequestFreshGroup(self, _cmd, groupJID, deltaUpdate, completion);
    }
}

static void WAGRDF2InstallRequestHooksIfAvailable(void) {
    @synchronized ([NSObject class]) {
        if (gWAGRDF2RequestHooksInstalled) return;
        Class cls = NSClassFromString(@"XMPPConnectionABPropsRequestManager") ?:
                    objc_getClass("XMPPConnectionABPropsRequestManager");
        if (!cls) return;

        BOOL installed = NO;
        SEL fresh = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
        Method freshMethod = class_getInstanceMethod(cls, fresh);
        if (freshMethod && method_getNumberOfArguments(freshMethod) == 4 &&
            WAGRDF2MethodReturnsVoid(freshMethod) &&
            WAGRDF2ArgumentIsBool(freshMethod, 2) &&
            WAGRDF2ArgumentIsObject(freshMethod, 3)) {
            MSHookMessageEx(cls, fresh, (IMP)hook_WAGRDF2RequestFresh,
                            (IMP *)&orig_WAGRDF2RequestFresh);
            installed |= (orig_WAGRDF2RequestFresh != NULL);
        }

        SEL grouped = NSSelectorFromString(@"requestFreshABPropsWithGroupJID:deltaUpdate:completion:");
        Method groupedMethod = class_getInstanceMethod(cls, grouped);
        if (groupedMethod && method_getNumberOfArguments(groupedMethod) == 5 &&
            WAGRDF2MethodReturnsVoid(groupedMethod) &&
            WAGRDF2ArgumentIsObject(groupedMethod, 2) &&
            WAGRDF2ArgumentIsBool(groupedMethod, 3) &&
            WAGRDF2ArgumentIsObject(groupedMethod, 4)) {
            MSHookMessageEx(cls, grouped, (IMP)hook_WAGRDF2RequestFreshGroup,
                            (IMP *)&orig_WAGRDF2RequestFreshGroup);
            installed |= (orig_WAGRDF2RequestFreshGroup != NULL);
        }
        gWAGRDF2RequestHooksInstalled = installed;
        if (installed) WAGRLogAppend(@"[ABProps][FetchV2] exact XMPP request hooks installed");
    }
}

static id WAGRDF2FindRequestManager(id root,
                                    NSMutableSet<NSValue *> *visited,
                                    NSUInteger depth) {
    if (!root || depth > 5) return nil;
    if (WAGRDF2ObjectCanFreshFetch(root)) return root;

    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    for (NSString *selectorName in @[
        @"abPropsRequestManager", @"abPropertiesRequestManager", @"requestManager",
        @"xmppConnection", @"connection", @"syncManager", @"userContext",
        @"propertiesManager", @"abPropsManager", @"abProperties"
    ]) {
        id child = WAGRDF2CallObjectNoArg(root, selectorName);
        if (!child || child == root) continue;
        id found = WAGRDF2FindRequestManager(child, visited, depth + 1);
        if (found) return found;
    }

    for (Class current = [root class]; current && current != NSObject.class;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *rawType = ivar_getTypeEncoding(ivar);
            const char *rawName = ivar_getName(ivar);
            if (!rawType || !rawName || WAGRDF2SkipQualifiers(rawType)[0] != '@') continue;
            NSString *name = [[NSString stringWithUTF8String:rawName] lowercaseString] ?: @"";
            BOOL interesting = [name containsString:@"abprop"] || [name containsString:@"request"] ||
                               [name containsString:@"xmpp"] || [name containsString:@"connection"] ||
                               [name containsString:@"sync"];
            if (!interesting) continue;
            id child = nil;
            @try { child = object_getIvar(root, ivar); }
            @catch (__unused NSException *exception) { child = nil; }
            if (!child || child == root) continue;
            id found = WAGRDF2FindRequestManager(child, visited, depth + 1);
            if (found) { free(ivars); return found; }
        }
        free(ivars);
    }
    return nil;
}

static id WAGRDF2ResolveRequestManager(id userContext, NSString **source) {
    WAGRDF2InstallRequestHooksIfAvailable();
    WAGRDF2EnsureRequestLock();
    @synchronized (gWAGRDF2RequestLock) {
        if (WAGRDF2ObjectCanFreshFetch(gWAGRDF2RequestManager)) {
            if (source) *source = @"captured exact XMPPConnectionABPropsRequestManager";
            return gWAGRDF2RequestManager;
        }
    }

    id context = userContext ?: WAGRCurrentUserContext();
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    id manager = WAGRDF2FindRequestManager(context, visited, 0);
    if (manager) {
        WAGRDF2RememberRequestManager(manager, @"userContext object graph");
        if (source) *source = @"userContext object graph";
        return manager;
    }
    if (source) *source = @"not resolved";
    return nil;
}

static BOOL (*orig_WAGRDF2TriggerNativeFetch)(id, NSString **) = NULL;

static BOOL hook_WAGRDF2TriggerNativeFetch(id userContext, NSString **diagnostic) {
    NSString *source = nil;
    id manager = WAGRDF2ResolveRequestManager(userContext, &source);
    if (!manager) {
        NSString *text = [NSString stringWithFormat:
            @"exact requestFreshABProps:withCompletion: manager not resolved (%@); no heuristic method was invoked",
            source ?: @"unknown"];
        WAGRLogAppendF(@"[ABProps][FetchV2] %@", text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 4 ||
        !WAGRDF2MethodReturnsVoid(method) ||
        !WAGRDF2ArgumentIsBool(method, 2) || !WAGRDF2ArgumentIsObject(method, 3)) {
        NSString *text = @"requestFreshABProps:withCompletion: exists with an unexpected ABI; request not sent";
        WAGRLogAppendF(@"[ABProps][FetchV2] %@", text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    __block BOOL completionSeen = NO;
    id completion = [^(id first, id second) {
        (void)first; (void)second;
        completionSeen = YES;
        WAGRLogAppend(@"[ABProps][FetchV2] native completion invoked");
    } copy];

    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, selector, NO, completion);
    } @catch (NSException *exception) {
        NSString *text = [NSString stringWithFormat:@"requestFreshABProps:NO threw %@",
                          exception.reason ?: @"exception"];
        WAGRLogAppendF(@"[ABProps][FetchV2] %@", text);
        if (diagnostic) *diagnostic = text;
        return NO;
    }

    NSString *text = [NSString stringWithFormat:
        @"exact request sent via -[%@ requestFreshABProps:NO withCompletion:] (%@)%@",
        NSStringFromClass([manager class]) ?: @"XMPPConnectionABPropsRequestManager",
        source ?: @"resolved manager", completionSeen ? @"; completion already fired" : @""];
    WAGRLogAppendF(@"[ABProps][FetchV2] %@", text);
    if (diagnostic) *diagnostic = text;
    return YES;
}

#pragma mark - 2/3. Deterministic FBMobileConfigContextManager resolution

static id (*orig_WAGRDF2MobileConfigContextManager)(id) = NULL;

static BOOL WAGRDF2ManagerBoolean(id manager, NSString *selectorName, BOOL *available) {
    if (available) *available = NO;
    if (!manager) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    char t = WAGRDF2SkipQualifiers(raw)[0];
    if (!(t == 'B' || t == 'c' || t == 'C')) return NO;
    if (available) *available = YES;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(manager, selector); }
    @catch (__unused NSException *exception) { return NO; }
}

static BOOL WAGRDF2ManagerIsUsable(id manager) {
    if (!manager) return NO;
    NSString *name = NSStringFromClass([manager class]) ?: @"";
    if (![name containsString:@"FBMobileConfigContextManager"]) return NO;

    BOOL managerCheckAvailable = NO;
    BOOL configCheckAvailable = NO;
    BOOL hasManager = WAGRDF2ManagerBoolean(manager, @"hasValidManager", &managerCheckAvailable);
    BOOL hasConfig = WAGRDF2ManagerBoolean(manager, @"hasValidConfig", &configCheckAvailable);
    if (managerCheckAvailable && !hasManager) return NO;
    if (configCheckAvailable && !hasConfig) return NO;

    SEL stable = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], stable);
    return method && method_getNumberOfArguments(method) == 3;
}

static id WAGRDF2ClassManager(NSString *selectorName) {
    Class cls = NSClassFromString(@"FBMobileConfigContextManager") ?:
                objc_getClass("FBMobileConfigContextManager");
    if (!cls) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRDF2MethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id hook_WAGRDF2MobileConfigContextManager(id userContext) {
    id manager = orig_WAGRDF2MobileConfigContextManager
        ? orig_WAGRDF2MobileConfigContextManager(userContext) : nil;
    if (WAGRDF2ManagerIsUsable(manager)) return manager;

    for (NSString *selectorName in @[@"sessionlessContextManager", @"defaultValueContextManager"]) {
        id candidate = WAGRDF2ClassManager(selectorName);
        if (!WAGRDF2ManagerIsUsable(candidate)) continue;
        WAGRLogAppendF(@"[MobileConfig][ResolverV2] using +%@ -> %@",
                       selectorName, NSStringFromClass([candidate class]) ?: @"?");
        return candidate;
    }
    return manager;
}

#pragma mark - 4. Correct export semantics + final external MC stable IDs

static NSDictionary<NSString *, id> *(*orig_WAGRDF2NativeExport)(WAGRABPropsNativeSnapshot *) = NULL;

static uint64_t WAGRDF2ParseSpecifier(NSString *hex) {
    if (![hex isKindOfClass:NSString.class] || !hex.length) return 0;
    return strtoull(hex.UTF8String ?: "0", NULL, 0);
}

static uint64_t WAGRDF2ExternalStableId(id manager, uint64_t specifier) {
    if (!WAGRDF2ManagerIsUsable(manager) || !specifier) return 0;
    SEL selector = NSSelectorFromString(@"getStableIdFromParamSpecifier:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 3) return 0;
    @try {
        if (WAGRDF2MethodReturnsObject(method)) {
            id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            if ([value respondsToSelector:@selector(unsignedLongLongValue)]) {
                return [value unsignedLongLongValue];
            }
            return strtoull([[value description] UTF8String] ?: "0", NULL, 10);
        }
        char raw[64] = {0}; method_getReturnType(method, raw, sizeof(raw));
        switch (WAGRDF2SkipQualifiers(raw)[0]) {
            case 'B': case 'c': case 'C': case 's': case 'S': case 'i': case 'I':
            case 'l': case 'L': case 'q': case 'Q':
                return ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)(manager, selector, specifier);
            default: return 0;
        }
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static NSDictionary *WAGRDF2LoadMCNames(void) {
    static NSDictionary *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = WAGRMobileConfigNamesPath(WAGRCurrentUserContext());
        NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
        id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSMutableDictionary *configs = [NSMutableDictionary dictionary];
        NSMutableDictionary *parameters = [NSMutableDictionary dictionary];

        void (^consumeLine)(NSString *) = ^(NSString *line) {
            if (![line isKindOfClass:NSString.class] || !line.length) return;
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@":"];
            if (parts.count < 2) return;
            unsigned long long configId = strtoull(parts[0].UTF8String ?: "0", NULL, 10);
            if (!configId) return;
            if (parts[1].length) configs[@(configId)] = parts[1];
            for (NSUInteger i = 2; i + 1 < parts.count; i += 2) {
                NSInteger parameterIndex = [parts[i] integerValue];
                NSString *parameterName = parts[i + 1];
                if (parameterName.length) {
                    parameters[[NSString stringWithFormat:@"%llu:%ld", configId, (long)parameterIndex]] = parameterName;
                }
            }
        };

        if ([object isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)object) if ([item isKindOfClass:NSString.class]) consumeLine(item);
        } else if ([object isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                (void)stop;
                NSString *keyString = [key isKindOfClass:NSString.class] ? key : [key description];
                NSArray<NSString *> *keyParts = [keyString componentsSeparatedByString:@":"];
                unsigned long long configId = keyParts.count ? strtoull(keyParts[0].UTF8String ?: "0", NULL, 10) : 0;
                if (!configId) return;
                if (keyParts.count > 1 && keyParts[1].length) configs[@(configId)] = keyParts[1];
                if (![value isKindOfClass:NSArray.class]) return;
                for (id rowObject in (NSArray *)value) {
                    if (![rowObject isKindOfClass:NSString.class]) continue;
                    NSArray<NSString *> *row = [(NSString *)rowObject componentsSeparatedByString:@":"];
                    if (row.count < 2) continue;
                    NSInteger parameterIndex = [row[0] integerValue];
                    NSString *parameterName = [row[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (parameterName.length) {
                        parameters[[NSString stringWithFormat:@"%llu:%ld", configId, (long)parameterIndex]] = parameterName;
                    }
                }
            }];
        }
        cached = @{ @"configs": [configs copy], @"parameters": [parameters copy] };
    });
    return cached ?: @{};
}

static NSDictionary<NSString *, id> *hook_WAGRDF2NativeExport(WAGRABPropsNativeSnapshot *snapshot) {
    NSDictionary *base = orig_WAGRDF2NativeExport ? orig_WAGRDF2NativeExport(snapshot) : @{};
    if (![base isKindOfClass:NSDictionary.class]) return base ?: @{};

    NSMutableDictionary *document = [base mutableCopy];
    NSArray *baseEntries = [base[@"entries"] isKindOfClass:NSArray.class] ? base[@"entries"] : @[];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:baseEntries.count];
    id manager = WAGRMobileConfigContextManager(WAGRCurrentUserContext());
    NSDictionary *names = manager ? WAGRDF2LoadMCNames() : @{};
    NSDictionary *configNames = names[@"configs"] ?: @{};
    NSDictionary *parameterNames = names[@"parameters"] ?: @{};
    NSUInteger externalResolved = 0;

    for (id rawEntry in baseEntries) {
        if (![rawEntry isKindOfClass:NSDictionary.class]) {
            [entries addObject:rawEntry ?: NSNull.null];
            continue;
        }
        NSMutableDictionary *entry = [(NSDictionary *)rawEntry mutableCopy];
        NSDictionary *rawMC = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class] ? entry[@"mobileconfig"] : nil;
        if (rawMC) {
            NSMutableDictionary *mc = [rawMC mutableCopy];
            id compact = mc[@"parameter_stable_id"];
            if (compact) {
                mc[@"compact_parameter_token"] = compact;
                [mc removeObjectForKey:@"parameter_stable_id"];
            }

            uint64_t specifier = WAGRDF2ParseSpecifier(mc[@"param_specifier_hex"]);
            uint64_t external = manager ? WAGRDF2ExternalStableId(manager, specifier) : 0;
            if (external) {
                externalResolved++;
                mc[@"external_config_stable_id"] = @(external);
                NSString *configName = configNames[@(external)];
                if (configName.length) mc[@"config_name"] = configName;
                NSUInteger parameterIndex = [mc[@"parameter_index"] unsignedIntegerValue];
                NSString *parameterName = parameterNames[[NSString stringWithFormat:@"%llu:%lu",
                    external, (unsigned long)parameterIndex]];
                if (parameterName.length) mc[@"parameter_name"] = parameterName;
            }
            entry[@"mobileconfig"] = mc;
        }
        [entries addObject:entry];
    }

    document[@"format"] = @"WATweaks WhatsApp native ABProps snapshot v2";
    document[@"entries"] = entries;
    document[@"mobileconfig_resolution"] = @{
        @"manager_resolved": @(manager != nil),
        @"external_config_stable_ids_resolved": @(externalResolved),
        @"semantic_note": @"compact_parameter_token is the low-16 compact translation token; external_config_stable_id is resolved separately by FBMobileConfigContextManager"
    };
    return document;
}

#pragma mark - Installation

static void WAGRDF2InstallFunctionHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MSHookFunction((void *)WAGRABPropsTriggerNativeFetch,
                       (void *)hook_WAGRDF2TriggerNativeFetch,
                       (void **)&orig_WAGRDF2TriggerNativeFetch);
        MSHookFunction((void *)WAGRMobileConfigContextManager,
                       (void *)hook_WAGRDF2MobileConfigContextManager,
                       (void **)&orig_WAGRDF2MobileConfigContextManager);
        MSHookFunction((void *)WAGRABPropsNativeExportDocument,
                       (void *)hook_WAGRDF2NativeExport,
                       (void **)&orig_WAGRDF2NativeExport);
        WAGRLogAppend(@"[Dogfood2Fixups] ABProps fetch/export + MobileConfig resolver v2 installed");
    });
}

static void WAGRDF2ImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    dispatch_async(dispatch_get_main_queue(), ^{
        WAGRDF2InstallRequestHooksIfAvailable();
        WAGRMobileConfigEnsureCaptureHooksInstalled();
    });
}

__attribute__((constructor))
static void WAGRABPropsDogfood2FixupsCtor(void) {
    @autoreleasepool {
        WAGRDF2EnsureRequestLock();
        WAGRDF2InstallFunctionHooks();
        WAGRMobileConfigEnsureCaptureHooksInstalled();
        WAGRDF2InstallRequestHooksIfAvailable();
        _dyld_register_func_for_add_image(WAGRDF2ImageAdded);
    }
}
