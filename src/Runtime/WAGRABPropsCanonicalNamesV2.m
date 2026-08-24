#import "WAGRABPropsCanonicalNamesV2.h"
#import "WAGRLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static NSDictionary<NSString *, NSString *> *gWAGRCanonicalCodeNames = nil;
static NSObject *gWAGRCanonicalCodeNamesLock = nil;
static NSMutableDictionary<NSString *, NSString *> *gWAGRCanonicalSchemaFallback = nil;
static NSObject *gWAGRCanonicalSchemaFallbackLock = nil;

static BOOL WAGRCanonicalStringIsDecimal(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return NO;
    NSCharacterSet *nonDigits = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    return [value rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static const char *WAGRCanonicalSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRCanonicalMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRCanonicalSkipQualifiers(raw)[0] == '@';
}

static BOOL WAGRCanonicalMethodWordArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char raw[64] = {0};
    method_getArgumentType(method, index, raw, sizeof(raw));
    const char *type = WAGRCanonicalSkipQualifiers(raw);
    if (!*type) return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRCanonicalMethodWordReturn(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *type = WAGRCanonicalSkipQualifiers(raw);
    if (!*type || type[0] == '@' || type[0] == 'v' || type[0] == 'f' || type[0] == 'd') return NO;
    NSUInteger size = 0, alignment = 0;
    @try { NSGetSizeAndAlignment(type, &size, &alignment); }
    @catch (__unused NSException *exception) { return NO; }
    return size > 0 && size <= sizeof(uint64_t);
}

static BOOL WAGRCanonicalRuntimeAddressRange(const struct mach_header_64 *header,
                                              uintptr_t address,
                                              size_t length) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    intptr_t slide = 0;
    BOOL slideKnown = NO;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (!lc->cmdsize) return NO;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (!slideKnown && strcmp(seg->segname, SEG_TEXT) == 0) {
                slide = (intptr_t)((uintptr_t)header - (uintptr_t)seg->vmaddr);
                slideKnown = YES;
            }
        }
        cursor += lc->cmdsize;
    }
    if (!slideKnown) return NO;

    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (!lc->cmdsize) return NO;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            uintptr_t start = (uintptr_t)((intptr_t)seg->vmaddr + slide);
            uintptr_t end = start + (uintptr_t)seg->vmsize;
            if (address >= start && address <= end && length <= (size_t)(end - address)) return YES;
        }
        cursor += lc->cmdsize;
    }
    return NO;
}

static BOOL WAGRCanonicalDecodeDescriptorAddress(IMP implementation, uintptr_t *outDescriptor) {
    if (!implementation || !outDescriptor) return NO;
    uintptr_t pc = (uintptr_t)implementation;
    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return NO;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (!WAGRCanonicalRuntimeAddressRange(header, pc, 8)) return NO;

    uint32_t adrp = 0;
    uint32_t add = 0;
    memcpy(&adrp, (const void *)pc, sizeof(adrp));
    memcpy(&add, (const void *)(pc + 4), sizeof(add));

    // Current WAAB getter shape in the supplied WhatsApp build:
    //   adrp x2, <CFConstantString page>
    //   add  x2, x2, <offset>
    //   b    <generic typed ABProp accessor>
    if ((adrp & 0x9F00001F) != 0x90000002) return NO;
    if ((add & 0x7F0003FF) != 0x11000042) return NO;

    uint64_t immlo = (adrp >> 29) & 0x3;
    uint64_t immhi = (adrp >> 5) & 0x7FFFF;
    int64_t pageDelta = (int64_t)((immhi << 2) | immlo);
    if (pageDelta & (1LL << 20)) pageDelta |= ~((1LL << 21) - 1);
    pageDelta <<= 12;

    uintptr_t page = (pc & ~(uintptr_t)0xFFF) + (intptr_t)pageDelta;
    uint64_t imm12 = (add >> 10) & 0xFFF;
    uint64_t shift = (add >> 22) & 0x1;
    uintptr_t descriptor = page + (uintptr_t)(imm12 << (shift ? 12 : 0));
    if (!WAGRCanonicalRuntimeAddressRange(header, descriptor, 32)) return NO;
    *outDescriptor = descriptor;
    return YES;
}

static NSString *WAGRCanonicalCodeFromGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    IMP implementation = method_getImplementation(method);
    uintptr_t descriptor = 0;
    if (!WAGRCanonicalDecodeDescriptorAddress(implementation, &descriptor)) return nil;

    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return nil;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;

    const char *characters = NULL;
    uint64_t length = 0;
    memcpy(&characters, (const void *)(descriptor + 16), sizeof(characters));
    memcpy(&length, (const void *)(descriptor + 24), sizeof(length));
    if (!characters || length == 0 || length > 10) return nil;
    if (!WAGRCanonicalRuntimeAddressRange(header, (uintptr_t)characters, (size_t)length + 1)) return nil;

    for (uint64_t i = 0; i < length; i++) {
        char c = characters[i];
        if (c < '0' || c > '9') return nil;
    }
    if (characters[length] != '\0') return nil;
    return [[NSString alloc] initWithBytes:characters
                                    length:(NSUInteger)length
                                  encoding:NSASCIIStringEncoding];
}

static BOOL WAGRCanonicalClassMayOwnABPropGetters(Class cls) {
    if (!cls) return NO;
    const char *rawImage = class_getImageName(cls);
    if (!rawImage) return NO;
    NSString *path = [NSString stringWithUTF8String:rawImage] ?: @"";
    NSString *bundlePath = NSBundle.mainBundle.bundlePath ?: @"";
    if (bundlePath.length && [path hasPrefix:bundlePath]) return YES;
    return [path rangeOfString:@"/WhatsApp.app/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSDictionary<NSString *, NSString *> *WAGRCanonicalBuildMap(void) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionaryWithCapacity:9000];
    unsigned int classCount = 0;
    __unsafe_unretained Class *classes = objc_copyClassList(&classCount);
    NSUInteger scannedClasses = 0;
    NSUInteger scannedMethods = 0;

    for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
        Class cls = classes[classIndex];
        if (!WAGRCanonicalClassMayOwnABPropGetters(cls)) continue;
        scannedClasses++;

        for (NSUInteger meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(cls) : cls;
            if (!owner) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            if (!methods) continue;
            for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
                Method method = methods[methodIndex];
                if (!method || method_getNumberOfArguments(method) != 2) continue;
                SEL selector = method_getName(method);
                NSString *name = selector ? NSStringFromSelector(selector) : nil;
                if (!name.length || [name containsString:@":"]) continue;
                scannedMethods++;
                NSString *code = WAGRCanonicalCodeFromGetter(method);
                if (!WAGRCanonicalStringIsDecimal(code)) continue;
                NSString *existing = map[code];
                if (!existing.length || ([name containsString:@"_"] && ![existing containsString:@"_"])) {
                    map[code] = name;
                }
            }
            free(methods);
        }
    }
    free(classes);

    WAGRLogAppendF(@"[ABProps][NamesV2] read-only native map=%lu appClasses=%lu noArgMethods=%lu",
                   (unsigned long)map.count,
                   (unsigned long)scannedClasses,
                   (unsigned long)scannedMethods);
    return [map copy];
}

static NSDictionary<NSString *, NSString *> *WAGRCanonicalMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRCanonicalCodeNamesLock = [NSObject new];
        gWAGRCanonicalCodeNames = WAGRCanonicalBuildMap();
    });
    @synchronized (gWAGRCanonicalCodeNamesLock) {
        return gWAGRCanonicalCodeNames ?: @{};
    }
}

static NSString *WAGRCanonicalParameterPart(NSString *fullName) {
    if (!fullName.length) return nil;
    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0 && NSMaxRange(dot) < fullName.length) {
        return [fullName substringFromIndex:NSMaxRange(dot)];
    }
    return fullName;
}

// Independent fallback through WhatsApp's own current-build MobileConfig schema:
// AB stable ID -> WAMCEvaluation paramSpecifier -> StartupConfigs param name.
// It is read-only, requires neither id_name_mapping.json nor an external config
// stable ID, and therefore still works before Developer/Internal Settings has
// materialized any name-map file in the AppGroup.
static NSString *WAGRCanonicalSchemaNameForCode(NSString *code) {
    if (!WAGRCanonicalStringIsDecimal(code)) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRCanonicalSchemaFallbackLock = [NSObject new];
        gWAGRCanonicalSchemaFallback = [NSMutableDictionary dictionary];
    });

    @synchronized (gWAGRCanonicalSchemaFallbackLock) {
        NSString *cached = gWAGRCanonicalSchemaFallback[code];
        if (cached.length) return cached;
    }

    Class evaluation = NSClassFromString(@"WAMCEvaluation") ?: objc_getClass("WAMCEvaluation");
    SEL specifierSelector = NSSelectorFromString(@"getMCSpecifierForStableId:");
    Method specifierMethod = class_getClassMethod(evaluation, specifierSelector);
    if (!evaluation || !specifierMethod || method_getNumberOfArguments(specifierMethod) != 3 ||
        !WAGRCanonicalMethodWordArgument(specifierMethod, 2) ||
        !WAGRCanonicalMethodWordReturn(specifierMethod)) return nil;

    uint64_t stableId = strtoull(code.UTF8String ?: "0", NULL, 10);
    uint64_t specifier = 0;
    @try {
        specifier = ((uint64_t (*)(id, SEL, uint64_t))objc_msgSend)((id)evaluation,
                                                                    specifierSelector,
                                                                    stableId);
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (!specifier || (specifier & (1ULL << 62))) return nil;

    Class startup = NSClassFromString(@"FBMobileConfigStartupConfigs") ?:
                    objc_getClass("FBMobileConfigStartupConfigs");
    SEL instanceSelector = NSSelectorFromString(@"getInstance");
    Method instanceMethod = class_getClassMethod(startup, instanceSelector);
    if (!startup || !instanceMethod || method_getNumberOfArguments(instanceMethod) != 2 ||
        !WAGRCanonicalMethodReturnsObject(instanceMethod)) return nil;

    id instance = nil;
    @try { instance = ((id (*)(id, SEL))objc_msgSend)((id)startup, instanceSelector); }
    @catch (__unused NSException *exception) { instance = nil; }
    if (!instance) return nil;

    SEL nameSelector = NSSelectorFromString(@"convertSpecifierToParamName:");
    Method nameMethod = class_getInstanceMethod([instance class], nameSelector);
    if (!nameMethod || method_getNumberOfArguments(nameMethod) != 3 ||
        !WAGRCanonicalMethodReturnsObject(nameMethod) ||
        !WAGRCanonicalMethodWordArgument(nameMethod, 2)) return nil;

    NSString *fullName = nil;
    @try {
        id value = ((id (*)(id, SEL, uint64_t))objc_msgSend)(instance, nameSelector, specifier);
        if ([value isKindOfClass:NSString.class]) fullName = value;
    } @catch (__unused NSException *exception) {
        fullName = nil;
    }
    NSString *name = WAGRCanonicalParameterPart(fullName);
    if (!name.length) return nil;

    @synchronized (gWAGRCanonicalSchemaFallbackLock) {
        gWAGRCanonicalSchemaFallback[code] = name;
    }
    return name;
}

NSString *WAGRABPropsCanonicalNameForCode(NSString *code) {
    if (!WAGRCanonicalStringIsDecimal(code)) return nil;
    NSString *nativeGetter = WAGRCanonicalMap()[code];
    if (nativeGetter.length) return nativeGetter;
    return WAGRCanonicalSchemaNameForCode(code);
}

NSUInteger WAGRABPropsCanonicalNameCount(void) {
    return WAGRCanonicalMap().count;
}
