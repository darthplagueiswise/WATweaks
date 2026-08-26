#import "WAGRABPropsStableIDResolver.h"

#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>

static NSObject *gWAGRABIDLock;
static NSMutableDictionary<NSString *, id> *gWAGRABIDCache;

static inline int64_t WAGRABSignExtend(uint64_t value, unsigned bits) {
    uint64_t sign = 1ULL << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static BOOL WAGRABDecodeADRP(uint32_t instruction,
                             uintptr_t pc,
                             uintptr_t *outPage,
                             uint32_t *outRegister) {
    if ((instruction & 0x9F000000u) != 0x90000000u) return NO;
    uint64_t immlo = (instruction >> 29) & 0x3u;
    uint64_t immhi = (instruction >> 5) & 0x7FFFFu;
    int64_t immediate = WAGRABSignExtend((immhi << 2) | immlo, 21) << 12;
    if (outPage) *outPage = (pc & ~(uintptr_t)0xFFFu) + immediate;
    if (outRegister) *outRegister = instruction & 0x1Fu;
    return YES;
}

static BOOL WAGRABDecodeADDImmediate(uint32_t instruction,
                                     uint32_t wantedRegister,
                                     uintptr_t *outImmediate) {
    // ADD (immediate), either 32- or 64-bit, without flags.
    if ((instruction & 0x7F000000u) != 0x11000000u) return NO;
    uint32_t rd = instruction & 0x1Fu;
    uint32_t rn = (instruction >> 5) & 0x1Fu;
    if (rd != wantedRegister || rn != wantedRegister) return NO;
    uintptr_t immediate = (instruction >> 10) & 0xFFFu;
    if ((instruction >> 22) & 1u) immediate <<= 12;
    if (outImmediate) *outImmediate = immediate;
    return YES;
}

static NSString *WAGRABDecimalStringAtAddress(uintptr_t address,
                                               const Dl_info *implementationInfo) {
    if (!address || !implementationInfo || !implementationInfo->dli_fbase) return nil;

    Dl_info candidateInfo = {0};
    if (!dladdr((const void *)address, &candidateInfo) || !candidateInfo.dli_fbase) return nil;
    if (candidateInfo.dli_fbase != implementationInfo->dli_fbase) return nil;

    const char *string = (const char *)address;
    size_t length = strnlen(string, 12);
    if (length == 0 || length >= 12) return nil;
    for (size_t index = 0; index < length; index++) {
        if (string[index] < '0' || string[index] > '9') return nil;
    }
    unsigned long long value = strtoull(string, NULL, 10);
    if (!value || value > 9999999999ULL) return nil;
    return [[NSString alloc] initWithBytes:string length:length encoding:NSASCIIStringEncoding];
}

static NSString *WAGRABResolveFromMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    IMP implementation = method_getImplementation(method);
    if (!implementation) return nil;

    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return nil;

    const uint32_t *words = (const uint32_t *)(const void *)implementation;
    uintptr_t basePC = (uintptr_t)(const void *)implementation;

    // Current WA ABProp getters load a decimal descriptor with ADRP + ADD before
    // tail-calling a shared typed getter. Scan a small fixed instruction window,
    // validate candidates as in-image decimal C strings, and never dereference
    // an address that dladdr cannot map to the same Mach-O image.
    for (NSUInteger index = 0; index < 12; index++) {
        uintptr_t page = 0;
        uint32_t reg = 0;
        uint32_t instruction = words[index];
        if (!WAGRABDecodeADRP(instruction, basePC + index * 4, &page, &reg)) continue;

        for (NSUInteger delta = 1; delta <= 4 && index + delta < 16; delta++) {
            uintptr_t addImmediate = 0;
            if (!WAGRABDecodeADDImmediate(words[index + delta], reg, &addImmediate)) continue;
            NSString *candidate = WAGRABDecimalStringAtAddress(page + addImmediate, &info);
            if (candidate.length) return candidate;
        }
    }
    return nil;
}

NSString *WAGRABPropsStableIDForTarget(NSString *className,
                                        NSString *selectorName,
                                        BOOL classMethod) {
    if (!className.length || !selectorName.length) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRABIDLock = [NSObject new];
        gWAGRABIDCache = [NSMutableDictionary dictionary];
    });

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%c|%@",
                          className, classMethod ? '+' : '-', selectorName];
    @synchronized (gWAGRABIDLock) {
        id cached = gWAGRABIDCache[cacheKey];
        if (cached) return cached == NSNull.null ? nil : cached;
    }

    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod ? class_getClassMethod(cls, selector)
                                : class_getInstanceMethod(cls, selector);
    NSString *stableID = WAGRABResolveFromMethod(method);

    @synchronized (gWAGRABIDLock) {
        gWAGRABIDCache[cacheKey] = stableID ?: (id)NSNull.null;
    }
    return stableID;
}
