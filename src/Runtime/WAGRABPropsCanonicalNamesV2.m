#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#import "WAGRLog.h"

extern NSString *WAGRWAABDisplayNameForKey(NSString *key);

static NSString *(*orig_WAGRDF2DisplayNameForKey)(NSString *) = NULL;
static NSDictionary<NSString *, NSString *> *gWAGRDF2NativeCodeNames = nil;
static NSObject *gWAGRDF2NativeCodeNamesLock = nil;

static BOOL WAGRDF2StringIsDecimal(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return NO;
    NSCharacterSet *nonDigits = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    return [value rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static BOOL WAGRDF2RuntimeAddressRange(const struct mach_header_64 *header,
                                       uintptr_t address,
                                       size_t length) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    intptr_t slide = 0;
    BOOL slideKnown = NO;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (!slideKnown && strcmp(seg->segname, SEG_TEXT) == 0) {
                slide = (intptr_t)((uintptr_t)header - (uintptr_t)seg->vmaddr);
                slideKnown = YES;
            }
        }
        if (!lc->cmdsize) return NO;
        cursor += lc->cmdsize;
    }
    if (!slideKnown) return NO;

    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            uintptr_t start = (uintptr_t)((intptr_t)seg->vmaddr + slide);
            uintptr_t end = start + (uintptr_t)seg->vmsize;
            if (address >= start && address <= end && length <= (size_t)(end - address)) return YES;
        }
        if (!lc->cmdsize) return NO;
        cursor += lc->cmdsize;
    }
    return NO;
}

static BOOL WAGRDF2DecodeDescriptorAddress(IMP implementation, uintptr_t *outDescriptor) {
    if (!implementation || !outDescriptor) return NO;
    uintptr_t pc = (uintptr_t)implementation;
    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return NO;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (!WAGRDF2RuntimeAddressRange(header, pc, 8)) return NO;

    uint32_t adrp = 0;
    uint32_t add = 0;
    memcpy(&adrp, (const void *)pc, sizeof(adrp));
    memcpy(&add, (const void *)(pc + 4), sizeof(add));

    // Current WAAB getter shape validated in the shipped build:
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
    if (!WAGRDF2RuntimeAddressRange(header, descriptor, 32)) return NO;
    *outDescriptor = descriptor;
    return YES;
}

static NSString *WAGRDF2CodeFromGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    IMP implementation = method_getImplementation(method);
    uintptr_t descriptor = 0;
    if (!WAGRDF2DecodeDescriptorAddress(implementation, &descriptor)) return nil;

    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return nil;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;

    const char *characters = NULL;
    uint64_t length = 0;
    memcpy(&characters, (const void *)(descriptor + 16), sizeof(characters));
    memcpy(&length, (const void *)(descriptor + 24), sizeof(length));
    if (!characters || length == 0 || length > 10) return nil;
    if (!WAGRDF2RuntimeAddressRange(header, (uintptr_t)characters, (size_t)length + 1)) return nil;

    for (uint64_t i = 0; i < length; i++) {
        char c = characters[i];
        if (c < '0' || c > '9') return nil;
    }
    if (characters[length] != '\0') return nil;
    return [[NSString alloc] initWithBytes:characters length:(NSUInteger)length encoding:NSASCIIStringEncoding];
}

static BOOL WAGRDF2ClassMayOwnABPropGetters(Class cls) {
    if (!cls) return NO;
    const char *rawImage = class_getImageName(cls);
    if (!rawImage) return NO;
    NSString *path = [NSString stringWithUTF8String:rawImage] ?: @"";
    NSString *bundlePath = NSBundle.mainBundle.bundlePath ?: @"";
    if (bundlePath.length && [path hasPrefix:bundlePath]) return YES;
    return [path rangeOfString:@"/WhatsApp.app/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSDictionary<NSString *, NSString *> *WAGRDF2BuildNativeCodeNameMap(void) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionaryWithCapacity:9000];
    unsigned int classCount = 0;
    __unsafe_unretained Class *classes = objc_copyClassList(&classCount);
    NSUInteger scannedClasses = 0;
    NSUInteger scannedMethods = 0;

    for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
        Class cls = classes[classIndex];
        if (!WAGRDF2ClassMayOwnABPropGetters(cls)) continue;
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
                NSString *code = WAGRDF2CodeFromGetter(method);
                if (!WAGRDF2StringIsDecimal(code)) continue;
                NSString *existing = map[code];
                if (!existing.length || ([name containsString:@"_"] && ![existing containsString:@"_"])) {
                    map[code] = name;
                }
            }
            free(methods);
        }
    }
    free(classes);

    WAGRLogAppendF(@"[ABProps][NamesV2] native map=%lu appClasses=%lu noArgMethods=%lu",
                   (unsigned long)map.count,
                   (unsigned long)scannedClasses,
                   (unsigned long)scannedMethods);
    return [map copy];
}

static NSDictionary<NSString *, NSString *> *WAGRDF2NativeCodeNameMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRDF2NativeCodeNamesLock = [NSObject new];
        gWAGRDF2NativeCodeNames = WAGRDF2BuildNativeCodeNameMap();
    });
    @synchronized (gWAGRDF2NativeCodeNamesLock) {
        return gWAGRDF2NativeCodeNames ?: @{};
    }
}

static NSString *hook_WAGRDF2DisplayNameForKey(NSString *key) {
    if (!key.length) return @"";
    if (WAGRDF2StringIsDecimal(key)) {
        NSString *native = WAGRDF2NativeCodeNameMap()[key];
        if (native.length) return native;
    }
    return orig_WAGRDF2DisplayNameForKey ? orig_WAGRDF2DisplayNameForKey(key) : key;
}

__attribute__((constructor))
static void WAGRABPropsCanonicalNamesV2Ctor(void) {
    @autoreleasepool {
        MSHookFunction((void *)WAGRWAABDisplayNameForKey,
                       (void *)hook_WAGRDF2DisplayNameForKey,
                       (void **)&orig_WAGRDF2DisplayNameForKey);
        WAGRLogAppend(@"[ABProps][NamesV2] runtime code->canonical selector resolver installed");
    }
}
