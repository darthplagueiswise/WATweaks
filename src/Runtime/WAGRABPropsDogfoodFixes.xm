#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>

#import "WAGRLog.h"

#pragma mark - WAContext exact ABProps request-manager bridge

static const char *WAGRDFNameSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRDFNameMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRDFNameSkipQualifiers(raw)[0] == '@';
}

static id WAGRDFExactABPropsRequestManager(id self, SEL _cmd) {
    (void)_cmd;
    SEL exact = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method method = class_getInstanceMethod([self class], exact);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRDFNameMethodReturnsObject(method)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(self, exact);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL gWAGRDFRequestAliasInstalled = NO;

static void WAGRDFInstallRequestManagerAlias(void) {
    if (gWAGRDFRequestAliasInstalled) return;
    Class cls = NSClassFromString(@"WAContext");
    if (!cls) return;
    SEL exact = NSSelectorFromString(@"xmppConnectionABPropsRequestManager");
    Method exactMethod = class_getInstanceMethod(cls, exact);
    if (!exactMethod || method_getNumberOfArguments(exactMethod) != 2 ||
        !WAGRDFNameMethodReturnsObject(exactMethod)) return;

    SEL alias = NSSelectorFromString(@"abPropsRequestManager");
    Method existing = class_getInstanceMethod(cls, alias);
    if (existing || class_addMethod(cls, alias, (IMP)WAGRDFExactABPropsRequestManager, "@16@0:8")) {
        gWAGRDFRequestAliasInstalled = YES;
        WAGRLogAppend(@"[ABProps][FetchV2] WAContext abPropsRequestManager -> xmppConnectionABPropsRequestManager bridge ready");
    }
}

#pragma mark - Current-build canonical ABProp names

static int64_t WAGRDFSignExtend(uint64_t value, unsigned int bits) {
    const uint64_t sign = 1ULL << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static NSString *WAGRDFABNativeTypeName(Method method) {
    if (!method) return @"unknown";
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    switch (WAGRDFNameSkipQualifiers(raw)[0]) {
        case 'B': case 'c': case 'C': return @"bool";
        case 'q': case 'Q': case 'i': case 'I': case 'l': case 'L':
        case 's': case 'S': return @"int";
        case 'd': return @"double";
        case 'f': return @"float";
        case '@': return @"object";
        default: return @"unknown";
    }
}

static BOOL WAGRDFAddressBelongsToImage(uintptr_t address, const void *expectedBase) {
    if (!address) return NO;
    Dl_info info = {0};
    if (!dladdr((const void *)address, &info) || !info.dli_fbase) return NO;
    return !expectedBase || info.dli_fbase == expectedBase;
}

static NSString *WAGRDFABCodeFromGetterIMP(IMP implementation) {
#if defined(__arm64__)
    if (!implementation) return nil;
    Dl_info impInfo = {0};
    if (!dladdr((const void *)implementation, &impInfo) || !impInfo.dli_fbase) return nil;

    const uint32_t *words = (const uint32_t *)(const void *)implementation;
    uint32_t adrp = words[0];
    uint32_t add = words[1];
    uint32_t branch = words[2];

    // Current SharedModules/WhatsApp WAAB getter shape:
    // adrp x2, descriptor-page; add x2, x2, offset; b typed-accessor.
    if ((adrp & 0x9F000000U) != 0x90000000U || (adrp & 0x1FU) != 2U) return nil;
    if ((add & 0xFF000000U) != 0x91000000U ||
        (add & 0x1FU) != 2U || ((add >> 5) & 0x1FU) != 2U) return nil;
    if ((branch & 0x7C000000U) != 0x14000000U) return nil;

    uint64_t imm21 = ((((uint64_t)adrp >> 5) & 0x7FFFFULL) << 2) |
                     (((uint64_t)adrp >> 29) & 0x3ULL);
    int64_t pageDelta = WAGRDFSignExtend(imm21, 21) << 12;
    uintptr_t pc = (uintptr_t)implementation;
    uintptr_t page = (pc & ~(uintptr_t)0xFFF) + pageDelta;
    uint64_t imm12 = ((uint64_t)add >> 10) & 0xFFFULL;
    if ((add >> 22) & 1U) imm12 <<= 12;
    uintptr_t descriptor = page + (uintptr_t)imm12;

    if (!WAGRDFAddressBelongsToImage(descriptor, impInfo.dli_fbase) ||
        !WAGRDFAddressBelongsToImage(descriptor + 31, impInfo.dli_fbase)) return nil;

    uintptr_t chars = 0;
    uint64_t length = 0;
    memcpy(&chars, (const void *)(descriptor + 16), sizeof(chars));
    memcpy(&length, (const void *)(descriptor + 24), sizeof(length));
    if (!chars || length == 0 || length > 10) return nil;
    if (!WAGRDFAddressBelongsToImage(chars, impInfo.dli_fbase) ||
        !WAGRDFAddressBelongsToImage(chars + (uintptr_t)length - 1, impInfo.dli_fbase)) return nil;

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

static NSDictionary<NSString *, NSDictionary *> *WAGRDFCanonicalABPropCatalog(void) {
    static NSDictionary *catalog = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"WAABProperties");
        if (!cls) {
            catalog = @{};
            return;
        }

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSMutableDictionary *mapping = [NSMutableDictionary dictionaryWithCapacity:9000];
        for (unsigned int index = 0; index < methodCount; index++) {
            Method method = methods[index];
            if (!method || method_getNumberOfArguments(method) != 2) continue;
            NSString *name = NSStringFromSelector(method_getName(method));
            if (!name.length || [name containsString:@":"]) continue;
            NSString *code = WAGRDFABCodeFromGetterIMP(method_getImplementation(method));
            if (!code.length) continue;

            NSDictionary *existing = mapping[code];
            NSString *oldName = [existing[@"name"] isKindOfClass:NSString.class] ? existing[@"name"] : @"";
            BOOL candidateCanonical = [name containsString:@"_"] && [name isEqualToString:name.lowercaseString];
            BOOL oldCanonical = [oldName containsString:@"_"] && [oldName isEqualToString:oldName.lowercaseString];
            if (!existing || (candidateCanonical && !oldCanonical)) {
                mapping[code] = @{
                    @"name": name,
                    @"type": WAGRDFABNativeTypeName(method),
                };
            }
        }
        free(methods);
        catalog = [mapping copy];
        WAGRLogAppendF(@"[ABProps][CatalogV2] %lu canonical wire IDs decoded from live WAABProperties (%u methods)",
                       (unsigned long)catalog.count, methodCount);
    });
    return catalog ?: @{};
}

static void (*orig_WAGRDFSnapshotReload)(id, SEL) = NULL;
static BOOL gWAGRDFSnapshotHookInstalled = NO;

static void hook_WAGRDFSnapshotReload(id self, SEL _cmd) {
    if (orig_WAGRDFSnapshotReload) orig_WAGRDFSnapshotReload(self, _cmd);

    NSDictionary *document = nil;
    @try { document = [self valueForKey:@"exportDocument"]; }
    @catch (__unused NSException *exception) { document = nil; }
    if (![document isKindOfClass:NSDictionary.class] || !document.count) return;

    NSDictionary *catalog = WAGRDFCanonicalABPropCatalog();
    NSArray *rawEntries = [document[@"entries"] isKindOfClass:NSArray.class] ? document[@"entries"] : @[];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:rawEntries.count];
    NSUInteger named = 0;

    for (id rawEntry in rawEntries) {
        if (![rawEntry isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry = [(NSDictionary *)rawEntry mutableCopy];
        NSString *code = [entry[@"code"] description] ?: @"";
        NSDictionary *canonical = [catalog[code] isKindOfClass:NSDictionary.class] ? catalog[code] : nil;
        NSString *name = [canonical[@"name"] isKindOfClass:NSString.class] ? canonical[@"name"] : nil;
        if (name.length) {
            entry[@"name"] = name;
            entry[@"type"] = canonical[@"type"] ?: @"unknown";
            named++;
        }
        [entries addObject:entry];
    }

    NSMutableDictionary *enriched = [document mutableCopy];
    enriched[@"entries"] = entries;
    enriched[@"canonical_catalog"] = @{
        @"source": @"live WAABProperties getter descriptors from loaded SharedModules + WhatsApp categories",
        @"catalog_codes": @(catalog.count),
        @"snapshot_named": @(named),
        @"snapshot_entries": @(entries.count),
    };

    @try {
        [self setValue:enriched forKey:@"exportDocument"];
        [self setValue:entries forKey:@"allEntries"];
        SEL applyFilter = NSSelectorFromString(@"applyFilter");
        if ([self respondsToSelector:applyFilter]) {
            ((void (*)(id, SEL))objc_msgSend)(self, applyFilter);
        }
    } @catch (NSException *exception) {
        WAGRLogAppendF(@"[ABProps][CatalogV2] snapshot enrichment failed: %@",
                       exception.reason ?: @"exception");
    }
}

static void WAGRDFInstallCanonicalNameHook(void) {
    if (gWAGRDFSnapshotHookInstalled) return;
    Class cls = NSClassFromString(@"WAGRABPropsSnapshotVC");
    SEL selector = NSSelectorFromString(@"reloadLocalSnapshot");
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return;
    MSHookMessageEx(cls, selector, (IMP)hook_WAGRDFSnapshotReload,
                    (IMP *)&orig_WAGRDFSnapshotReload);
    gWAGRDFSnapshotHookInstalled = (orig_WAGRDFSnapshotReload != NULL);
}

static void WAGRDFInstallCurrentBuildBridges(void) {
    WAGRDFInstallRequestManagerAlias();
    WAGRDFInstallCanonicalNameHook();
}

__attribute__((constructor))
static void WAGRABPropsCurrentBuildBridgeCtor(void) {
    @autoreleasepool {
        WAGRDFInstallCurrentBuildBridges();
        for (NSNumber *delay in @[@0.5, @1.5, @3.0, @6.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WAGRDFInstallCurrentBuildBridges();
            });
        }
    }
}
