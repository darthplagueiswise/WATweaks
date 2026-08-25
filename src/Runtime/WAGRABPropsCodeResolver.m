#import "WAGRABPropsCodeResolver.h"
#import "WAGRABPropsRuntime.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#include <stdint.h>
#include <string.h>

static NSCache<NSString *, NSString *> *gWAGRABCodeCache;

static BOOL WAGRABCodeRuntimeAddressRange(const struct mach_header_64 *header,
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

static BOOL WAGRABCodeDecodeDescriptorAddress(IMP implementation,
                                               uintptr_t *outDescriptor) {
    if (!implementation || !outDescriptor) return NO;
    uintptr_t pc = (uintptr_t)implementation;
    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return NO;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (!WAGRABCodeRuntimeAddressRange(header, pc, 8)) return NO;

    uint32_t adrp = 0, add = 0;
    memcpy(&adrp, (const void *)pc, sizeof(adrp));
    memcpy(&add, (const void *)(pc + 4), sizeof(add));

    // Current WhatsApp AB getter shape:
    //   adrp x2, <CFString page>
    //   add  x2, x2, <offset>
    //   b    <typed AB accessor>
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
    if (!WAGRABCodeRuntimeAddressRange(header, descriptor, 32)) return NO;
    *outDescriptor = descriptor;
    return YES;
}

static NSString *WAGRABCodeFromMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    IMP implementation = method_getImplementation(method);
    uintptr_t descriptor = 0;
    if (!WAGRABCodeDecodeDescriptorAddress(implementation, &descriptor)) return nil;

    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return nil;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;

    const char *characters = NULL;
    uint64_t length = 0;
    memcpy(&characters, (const void *)(descriptor + 16), sizeof(characters));
    memcpy(&length, (const void *)(descriptor + 24), sizeof(length));
    if (!characters || !length || length > 10) return nil;
    if (!WAGRABCodeRuntimeAddressRange(header, (uintptr_t)characters, (size_t)length + 1)) return nil;
    for (uint64_t i = 0; i < length; i++) {
        if (characters[i] < '0' || characters[i] > '9') return nil;
    }
    if (characters[length] != '\0') return nil;
    return [[NSString alloc] initWithBytes:characters length:(NSUInteger)length
                                  encoding:NSASCIIStringEncoding];
}

NSString *WAGRABPropsCodeForTarget(NSString *className,
                                    NSString *selectorName,
                                    BOOL isClassMethod) {
    if (!className.length || !selectorName.length) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWAGRABCodeCache = [NSCache new]; });
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@|%@", className,
                          isClassMethod ? @"+" : @"-", selectorName];
    NSString *cached = [gWAGRABCodeCache objectForKey:cacheKey];
    if (cached.length) return [cached isEqualToString:@"-"] ? nil : cached;

    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = isClassMethod ? class_getClassMethod(cls, selector)
                                  : class_getInstanceMethod(cls, selector);
    NSString *code = WAGRABCodeFromMethod(method);
    [gWAGRABCodeCache setObject:(code.length ? code : @"-") forKey:cacheKey];
    return code;
}

NSString *WAGRABPropsCodeForEntry(WAGRABPropEntry *entry) {
    if (!entry) return nil;
    return WAGRABPropsCodeForTarget(entry.className, entry.selectorName, entry.classMethod);
}
