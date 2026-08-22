#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>

#import "WAGRABPropsNativeStore.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

extern id WAGRCurrentUserContext(void);

#pragma mark - Shared helpers

static const char *WAGRSkipObjCQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMethodReturnsObject(Method method) {
    if (!method) return NO;
    char type[64] = {0};
    method_getReturnType(method, type, sizeof(type));
    return WAGRSkipObjCQualifiers(type)[0] == '@';
}

static BOOL WAGRMethodReturnsBool(Method method) {
    if (!method) return NO;
    char type[64] = {0};
    method_getReturnType(method, type, sizeof(type));
    const char c = WAGRSkipObjCQualifiers(type)[0];
    return c == 'B' || c == 'c' || c == 'C';
}

static id WAGRCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id WAGRCallClassObjectNoArg(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMethodReturnsObject(method)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL WAGRCallBoolNoArg(id target, NSString *selectorName, BOOL fallback) {
    if (!target || !selectorName.length) return fallback;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 || !WAGRMethodReturnsBool(method)) return fallback;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return fallback; }
}

#pragma mark - Exact ABProps request-manager bridge

static NSObject *gWAGRABRequestManagerLock = nil;
static id gWAGRABRequestManager = nil;
static id (*orig_WAGRABRequestManagerInit)(id, SEL, id, id) = NULL;
static id (*orig_WAGRABContextRequestManagerGetter)(id, SEL) = NULL;
static BOOL gWAGRABRequestManagerInitHooked = NO;
static BOOL gWAGRABContextRequestManagerGetterHooked = NO;
static BOOL gWAGRABContextAliasInstalled = NO;
static BOOL gWAGRABFetchAliasInstalled = NO;
static BOOL gWAGRABCurrentAliasInstalled = NO;

static void WAGRABEnsureRequestManagerLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWAGRABRequestManagerLock = [NSObject new]; });
}

static void WAGRABRememberRequestManager(id manager, NSString *source) {
    if (!manager) return;
    NSString *className = NSStringFromClass([manager class]) ?: @"";
    if (![className containsString:@"XMPPConnectionABPropsRequestManager"]) return;
    WAGRABEnsureRequestManagerLock();
    @synchronized (gWAGRABRequestManagerLock) { gWAGRABRequestManager = manager; }
    WAGRLogAppendF(@"[ABProps][FetchFix] captured %@ via %@", className, source ?: @"unknown");
}

static id hook_WAGRABRequestManagerInit(id self, SEL _cmd, id userContext, id xmppConnection) {
    id value = orig_WAGRABRequestManagerInit
        ? orig_WAGRABRequestManagerInit(self, _cmd, userContext, xmppConnection)
        : self;
    WAGRABRememberRequestManager(value, @"initWithUserContext:xmppConnection:");
    return value;
}

static id hook_WAGRABContextRequestManagerGetter(id self, SEL _cmd) {
    id manager = orig_WAGRABContextRequestManagerGetter
        ? orig_WAGRABContextRequestManagerGetter(self, _cmd) : nil;
    WAGRABRememberRequestManager(manager, @"WAContext.xmppConnectionABPropsRequestManager getter");
    return manager;
}

static id WAGRABCurrentRequestManager(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    WAGRABEnsureRequestManagerLock();
    @synchronized (gWAGRABRequestManagerLock) { return gWAGRABRequestManager; }
}

static id WAGRABContextRequestManagerAlias(id self, SEL _cmd) {
    (void)_cmd;
    id manager = WAGRCallObjectNoArg(self, @"xmppConnectionABPropsRequestManager");
    if (manager) WAGRABRememberRequestManager(manager, @"WAContext.xmppConnectionABPropsRequestManager");
    if (manager) return manager;
    return WAGRABCurrentRequestManager(nil, NULL);
}

static BOOL WAGRABExactFreshRequestSupported(id manager) {
    if (!manager) return NO;
    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    char arg2[32] = {0};
    char arg3[32] = {0};
    method_getArgumentType(method, 2, arg2, sizeof(arg2));
    method_getArgumentType(method, 3, arg3, sizeof(arg3));
    const char deltaType = WAGRSkipObjCQualifiers(arg2)[0];
    const char completionType = WAGRSkipObjCQualifiers(arg3)[0];
    return (deltaType == 'B' || deltaType == 'c' || deltaType == 'C') && completionType == '@';
}

static void WAGRABFetchFullAlias(id self, SEL _cmd) {
    (void)_cmd;
    WAGRABRememberRequestManager(self, @"wagr_fetchABProps");
    if (!WAGRABExactFreshRequestSupported(self)) {
        WAGRLogAppendF(@"[ABProps][FetchFix] exact selector ABI mismatch on %@", NSStringFromClass([self class]));
        return;
    }

    SEL selector = NSSelectorFromString(@"requestFreshABProps:withCompletion:");
    void (^completion)(void) = ^{
        WAGRLogAppendF(@"[ABProps][FetchFix] native requestFreshABProps completion fired");
    };
    @try {
        // deltaUpdate=NO forces a full account-scoped ABPROPS refresh. The native
        // method forwards to requestFreshABPropsWithGroupJID:nil deltaUpdate:NO.
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(self, selector, NO, completion);
        WAGRLogAppendF(@"[ABProps][FetchFix] requestFreshABProps:NO dispatched via %@",
                       NSStringFromClass([self class]));
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][FetchFix] requestFreshABProps threw %@", exception.reason ?: @"exception");
    }
}

static void WAGRInstallABPropsFetchFix(void) {
    Class managerClass = NSClassFromString(@"XMPPConnectionABPropsRequestManager");
    Class contextClass = NSClassFromString(@"WAContext");

    if (managerClass && !gWAGRABRequestManagerInitHooked) {
        SEL initSelector = NSSelectorFromString(@"initWithUserContext:xmppConnection:");
        Method initMethod = class_getInstanceMethod(managerClass, initSelector);
        if (initMethod && method_getNumberOfArguments(initMethod) == 4) {
            MSHookMessageEx(managerClass, initSelector, (IMP)hook_WAGRABRequestManagerInit,
                            (IMP *)&orig_WAGRABRequestManagerInit);
            gWAGRABRequestManagerInitHooked = (orig_WAGRABRequestManagerInit != NULL);
        }
    }

    if (contextClass && !gWAGRABContextRequestManagerGetterHooked) {
        SEL getter = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
        Method getterMethod = class_getInstanceMethod(contextClass, getter);
        if (getterMethod && method_getNumberOfArguments(getterMethod) == 2 && WAGRMethodReturnsObject(getterMethod)) {
            MSHookMessageEx(contextClass, getter, (IMP)hook_WAGRABContextRequestManagerGetter,
                            (IMP *)&orig_WAGRABContextRequestManagerGetter);
            gWAGRABContextRequestManagerGetterHooked = (orig_WAGRABContextRequestManagerGetter != NULL);
        }
    }

    if (managerClass && !gWAGRABFetchAliasInstalled) {
        SEL alias = NSSelectorFromString(@"wagr_fetchABProps");
        if (class_getInstanceMethod(managerClass, alias) ||
            class_addMethod(managerClass, alias, (IMP)WAGRABFetchFullAlias, "v16@0:8")) {
            gWAGRABFetchAliasInstalled = YES;
        }
    }

    if (managerClass && !gWAGRABCurrentAliasInstalled) {
        Class metaClass = object_getClass(managerClass);
        SEL current = NSSelectorFromString(@"current");
        if (class_getClassMethod(managerClass, current) ||
            class_addMethod(metaClass, current, (IMP)WAGRABCurrentRequestManager, "@16@0:8")) {
            gWAGRABCurrentAliasInstalled = YES;
        }
    }

    if (contextClass && !gWAGRABContextAliasInstalled) {
        SEL alias = NSSelectorFromString(@"abPropsRequestManager");
        if (class_getInstanceMethod(contextClass, alias) ||
            class_addMethod(contextClass, alias, (IMP)WAGRABContextRequestManagerAlias, "@16@0:8")) {
            gWAGRABContextAliasInstalled = YES;
        }
    }

    id context = WAGRCurrentUserContext();
    id manager = WAGRCallObjectNoArg(context, @"xmppConnectionABPropsRequestManager");
    if (manager) WAGRABRememberRequestManager(manager, @"current WAContext");
}

#pragma mark - Deterministic MobileConfig manager priming

static void (*orig_WAGRMCActivate)(id, SEL) = NULL;
static BOOL gWAGRMCActivateHooked = NO;

static BOOL WAGRMCManagerLooksUsable(id manager) {
    if (!manager) return NO;
    NSString *className = NSStringFromClass([manager class]) ?: @"";
    if (![className containsString:@"FBMobileConfigContextManager"]) return NO;
    BOOL validManager = WAGRCallBoolNoArg(manager, @"hasValidManager", YES);
    BOOL validConfig = WAGRCallBoolNoArg(manager, @"hasValidConfig", YES);
    return validManager && validConfig;
}

static void WAGRMCForceCapture(id manager, NSString *source) {
    if (!manager) return;
    WAGRMobileConfigEnsureCaptureHooksInstalled();
    SEL selector = NSSelectorFromString(@"getOverridesTablePath");
    Method method = class_getInstanceMethod([manager class], selector);
    if (method && method_getNumberOfArguments(method) == 2 && WAGRMethodReturnsObject(method)) {
        @try { (void)((id (*)(id, SEL))objc_msgSend)(manager, selector); }
        @catch (__unused NSException *exception) {}
    }
    WAGRLogAppendF(@"[MobileConfig][Prime] candidate=%@ source=%@ validManager=%@ validConfig=%@",
                   NSStringFromClass([manager class]), source ?: @"unknown",
                   WAGRCallBoolNoArg(manager, @"hasValidManager", NO) ? @"YES" : @"NO",
                   WAGRCallBoolNoArg(manager, @"hasValidConfig", NO) ? @"YES" : @"NO");
}

static void hook_WAGRMCActivate(id self, SEL _cmd) {
    if (orig_WAGRMCActivate) orig_WAGRMCActivate(self, _cmd);
    if (WAGRMCManagerLooksUsable(self)) WAGRMCForceCapture(self, @"FBMobileConfigContextManager.activate");
}

static void WAGRInstallMCActivationCapture(void) {
    if (gWAGRMCActivateHooked) return;
    Class cls = NSClassFromString(@"FBMobileConfigContextManager");
    SEL selector = NSSelectorFromString(@"activate");
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return;
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (WAGRSkipObjCQualifiers(returnType)[0] != 'v') return;
    MSHookMessageEx(cls, selector, (IMP)hook_WAGRMCActivate, (IMP *)&orig_WAGRMCActivate);
    gWAGRMCActivateHooked = (orig_WAGRMCActivate != NULL);
}

static id WAGRMCFindInObjectGraph(id root, NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!root || depth > 5) return nil;
    NSString *className = NSStringFromClass([root class]) ?: @"";
    if ([className containsString:@"FBMobileConfigContextManager"]) return root;
    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    for (NSString *selectorName in @[
        @"mobileConfig", @"mobileConfigContextManager", @"mobileConfigManager",
        @"contextManager", @"mcContextManager", @"manager", @"mainContext",
        @"sessionlessContextManager", @"defaultValueContextManager"
    ]) {
        id child = WAGRCallObjectNoArg(root, selectorName);
        if (!child || child == root) continue;
        id found = WAGRMCFindInObjectGraph(child, visited, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void WAGRPrimeMobileConfigManager(void) {
    WAGRMobileConfigEnsureCaptureHooksInstalled();
    WAGRInstallMCActivationCapture();
    id context = WAGRCurrentUserContext();

    id manager = WAGRMobileConfigContextManager(context);
    if (WAGRMCManagerLooksUsable(manager)) {
        WAGRMCForceCapture(manager, @"bridge/userContext");
        return;
    }

    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    id graphManager = WAGRMCFindInObjectGraph(context, visited, 0);
    if (WAGRMCManagerLooksUsable(graphManager)) {
        WAGRMCForceCapture(graphManager, @"WAContext graph");
        return;
    }

    Class cls = NSClassFromString(@"FBMobileConfigContextManager");
    for (NSString *selectorName in @[@"sessionlessContextManager", @"defaultValueContextManager"]) {
        id candidate = WAGRCallClassObjectNoArg(cls, selectorName);
        if (!WAGRMCManagerLooksUsable(candidate)) continue;
        WAGRMCForceCapture(candidate, [NSString stringWithFormat:@"+%@", selectorName]);
        return;
    }
}

#pragma mark - Canonical ABProp catalog decoded from the live current build

static int64_t WAGRSignExtend(uint64_t value, unsigned int bits) {
    const uint64_t sign = 1ULL << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static NSString *WAGRABNativeTypeName(Method method) {
    if (!method) return @"unknown";
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRSkipObjCQualifiers(raw)[0]) {
        case 'B': case 'c': case 'C': return @"bool";
        case 'q': case 'Q': case 'i': case 'I': case 'l': case 'L':
        case 's': case 'S': return @"int";
        case 'd': return @"double";
        case 'f': return @"float";
        case '@': return @"object";
        default: return @"unknown";
    }
}

static BOOL WAGRAddressBelongsToImage(uintptr_t address, const void *expectedBase) {
    if (!address) return NO;
    Dl_info info = {0};
    if (!dladdr((const void *)address, &info) || !info.dli_fbase) return NO;
    return !expectedBase || info.dli_fbase == expectedBase;
}

static NSString *WAGRABCodeFromGetterIMP(IMP implementation) {
#if defined(__arm64__)
    if (!implementation) return nil;
    Dl_info impInfo = {0};
    if (!dladdr((const void *)implementation, &impInfo) || !impInfo.dli_fbase) return nil;

    const uint32_t *words = (const uint32_t *)(const void *)implementation;
    uint32_t adrp = words[0];
    uint32_t add = words[1];
    uint32_t branch = words[2];

    // Canonical WAAB getter emitted in current SharedModules/WhatsApp categories:
    //   adrp x2, <descriptor-page>
    //   add  x2, x2, <descriptor-offset>
    //   b    <typed generic accessor>
    if ((adrp & 0x9F000000U) != 0x90000000U || (adrp & 0x1FU) != 2U) return nil;
    if ((add & 0xFF000000U) != 0x91000000U ||
        (add & 0x1FU) != 2U || ((add >> 5) & 0x1FU) != 2U) return nil;
    if ((branch & 0x7C000000U) != 0x14000000U) return nil;

    uint64_t imm21 = ((((uint64_t)adrp >> 5) & 0x7FFFFULL) << 2) |
                     (((uint64_t)adrp >> 29) & 0x3ULL);
    int64_t pageDelta = WAGRSignExtend(imm21, 21) << 12;
    uintptr_t pc = (uintptr_t)implementation;
    uintptr_t page = (pc & ~(uintptr_t)0xFFF) + pageDelta;
    uint64_t imm12 = ((uint64_t)add >> 10) & 0xFFFULL;
    if ((add >> 22) & 1U) imm12 <<= 12;
    uintptr_t descriptor = page + (uintptr_t)imm12;
    if (!WAGRAddressBelongsToImage(descriptor, impInfo.dli_fbase) ||
        !WAGRAddressBelongsToImage(descriptor + 31, impInfo.dli_fbase)) return nil;

    // Current-build descriptor begins with a constant CFString. At runtime its
    // chars pointer is fixed up at +16 and length at +24. Validate both source
    // and destination image ranges before dereferencing so unrelated methods
    // that happen to start with ADRP/ADD/B cannot crash this catalog pass.
    uintptr_t chars = 0;
    uint64_t length = 0;
    memcpy(&chars, (const void *)(descriptor + 16), sizeof(chars));
    memcpy(&length, (const void *)(descriptor + 24), sizeof(length));
    if (!chars || length == 0 || length > 10) return nil;
    if (!WAGRAddressBelongsToImage(chars, impInfo.dli_fbase) ||
        !WAGRAddressBelongsToImage(chars + (uintptr_t)length - 1, impInfo.dli_fbase)) return nil;

    char buffer[16] = {0};
    memcpy(buffer, (const void *)chars, (size_t)length);
    for (uint64_t index = 0; index < length; index++) {
        if (buffer[index] < '0' || buffer[index] > '9') return nil;
    }
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length
                                  encoding:NSASCIIStringEncoding];
#else
    (void)implementation;
    return nil;
#endif
}

static NSDictionary<NSString *, NSDictionary *> *WAGRCanonicalABPropCatalog(void) {
    static NSDictionary *catalog = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"WAABProperties");
        if (!cls) {
            catalog = @{};
            WAGRLogAppendF(@"[ABProps][Catalog] WAABProperties class unavailable");
            return;
        }

        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        NSMutableDictionary *mapping = [NSMutableDictionary dictionaryWithCapacity:9000];
        for (unsigned int index = 0; index < count; index++) {
            Method method = methods[index];
            if (!method || method_getNumberOfArguments(method) != 2) continue;
            SEL selector = method_getName(method);
            NSString *name = selector ? NSStringFromSelector(selector) : nil;
            if (!name.length || [name containsString:@":"]) continue;
            NSString *code = WAGRABCodeFromGetterIMP(method_getImplementation(method));
            if (!code.length) continue;

            NSDictionary *existing = mapping[code];
            BOOL candidateCanonical = [name containsString:@"_"] && [name isEqualToString:name.lowercaseString];
            NSString *existingName = [existing[@"name"] isKindOfClass:NSString.class] ? existing[@"name"] : @"";
            BOOL existingCanonical = [existingName containsString:@"_"] && [existingName isEqualToString:existingName.lowercaseString];
            if (!existing || (candidateCanonical && !existingCanonical)) {
                mapping[code] = @{ @"name" : name, @"type" : WAGRABNativeTypeName(method) };
            }
        }
        free(methods);
        catalog = [mapping copy];
        WAGRLogAppendF(@"[ABProps][Catalog] decoded %lu canonical wire codes from live WAABProperties methods (%u total methods)",
                       (unsigned long)catalog.count, count);
    });
    return catalog ?: @{};
}

static void (*orig_WAGRABSnapshotReload)(id, SEL) = NULL;
static BOOL gWAGRABSnapshotReloadHooked = NO;

static NSDictionary *WAGREnrichSnapshotDocument(NSDictionary *document) {
    if (![document isKindOfClass:NSDictionary.class]) return document ?: @{};
    NSDictionary *catalog = WAGRCanonicalABPropCatalog();
    NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class] ? document[@"entries"] : @[];
    NSMutableArray *enriched = [NSMutableArray arrayWithCapacity:entries.count];
    NSUInteger named = 0;

    for (id item in entries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry = [item mutableCopy];
        NSString *code = [entry[@"code"] description] ?: @"";
        NSDictionary *canonical = [catalog[code] isKindOfClass:NSDictionary.class] ? catalog[code] : nil;
        NSString *name = [canonical[@"name"] isKindOfClass:NSString.class] ? canonical[@"name"] : nil;
        if (name.length) {
            entry[@"name"] = name;
            if (canonical[@"type"]) entry[@"type"] = canonical[@"type"];
            named++;
        }

        if ([entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *mc = [entry[@"mobileconfig"] mutableCopy];
            id compactToken = mc[@"parameter_stable_id"];
            if (compactToken) {
                mc[@"compact_parameter_token"] = compactToken;
                [mc removeObjectForKey:@"parameter_stable_id"];
            }
            entry[@"mobileconfig"] = mc;
        }
        [enriched addObject:entry];
    }

    NSMutableDictionary *result = [document mutableCopy];
    result[@"format"] = @"WATweaks WhatsApp native ABProps snapshot v2";
    result[@"entries"] = enriched;
    result[@"canonical_catalog"] = @{
        @"source" : @"SharedModules + WhatsApp Objective-C WAABProperties getter descriptors",
        @"catalog_codes" : @(catalog.count),
        @"snapshot_named" : @(named),
        @"snapshot_entries" : @(enriched.count),
    };
    return result;
}

static void hook_WAGRABSnapshotReload(id self, SEL _cmd) {
    if (orig_WAGRABSnapshotReload) orig_WAGRABSnapshotReload(self, _cmd);
    NSDictionary *document = nil;
    @try { document = [self valueForKey:@"exportDocument"]; }
    @catch (__unused NSException *exception) { document = nil; }
    if (!document.count) return;

    NSDictionary *enriched = WAGREnrichSnapshotDocument(document);
    NSArray *entries = [enriched[@"entries"] isKindOfClass:NSArray.class] ? enriched[@"entries"] : @[];
    @try {
        [self setValue:enriched forKey:@"exportDocument"];
        [self setValue:entries forKey:@"allEntries"];
        SEL applyFilter = NSSelectorFromString(@"applyFilter");
        if ([self respondsToSelector:applyFilter]) ((void (*)(id, SEL))objc_msgSend)(self, applyFilter);
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][Catalog] snapshot enrichment failed: %@", exception.reason ?: @"exception");
    }
}

static void WAGRInstallSnapshotEnrichment(void) {
    if (gWAGRABSnapshotReloadHooked) return;
    Class cls = NSClassFromString(@"WAGRABPropsSnapshotVC");
    SEL selector = NSSelectorFromString(@"reloadLocalSnapshot");
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return;
    MSHookMessageEx(cls, selector, (IMP)hook_WAGRABSnapshotReload, (IMP *)&orig_WAGRABSnapshotReload);
    gWAGRABSnapshotReloadHooked = (orig_WAGRABSnapshotReload != NULL);
}

#pragma mark - MobileConfig export terminology repair

static NSDictionary *(*orig_WAGRMCMappingDictionaryRepresentation)(id, SEL) = NULL;
static BOOL gWAGRMCMappingDictionaryHooked = NO;

static NSDictionary *hook_WAGRMCMappingDictionaryRepresentation(id self, SEL _cmd) {
    NSDictionary *original = orig_WAGRMCMappingDictionaryRepresentation
        ? orig_WAGRMCMappingDictionaryRepresentation(self, _cmd) : @{};
    if (![original isKindOfClass:NSDictionary.class]) return original ?: @{};
    NSMutableDictionary *fixed = [original mutableCopy];
    id token = fixed[@"parameter_stable_id"];
    if (token) {
        fixed[@"compact_parameter_token"] = token;
        [fixed removeObjectForKey:@"parameter_stable_id"];
    }
    return fixed;
}

static void WAGRInstallMobileConfigTerminologyFix(void) {
    if (gWAGRMCMappingDictionaryHooked) return;
    Class cls = NSClassFromString(@"WAGRMobileConfigMapping");
    SEL selector = NSSelectorFromString(@"dictionaryRepresentation");
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2 || !WAGRMethodReturnsObject(method)) return;
    MSHookMessageEx(cls, selector, (IMP)hook_WAGRMCMappingDictionaryRepresentation,
                    (IMP *)&orig_WAGRMCMappingDictionaryRepresentation);
    gWAGRMCMappingDictionaryHooked = (orig_WAGRMCMappingDictionaryRepresentation != NULL);
}

#pragma mark - Installation / delayed retries

static void WAGRInstallDogfoodABMCFixes(void) {
    WAGRInstallABPropsFetchFix();
    WAGRInstallSnapshotEnrichment();
    WAGRInstallMobileConfigTerminologyFix();
    WAGRInstallMCActivationCapture();
    WAGRPrimeMobileConfigManager();
}

__attribute__((constructor))
static void WAGRABPropsDogfoodFixesCtor(void) {
    @autoreleasepool {
        WAGRInstallDogfoodABMCFixes();
        for (NSNumber *delay in @[@0.5, @1.5, @3.0, @6.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRInstallDogfoodABMCFixes();
            });
        }
    }
}
