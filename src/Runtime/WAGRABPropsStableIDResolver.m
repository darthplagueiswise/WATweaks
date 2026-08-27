#import "WAGRABPropsStableIDResolver.h"

#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static NSObject *gWAGRABIDLock;
static NSMutableDictionary<NSString *, id> *gWAGRABIDCache;
static NSUInteger gWAGRABIDAttempts;
static NSUInteger gWAGRABIDResolvedDirectCString;
static NSUInteger gWAGRABIDResolvedConstantString;
static NSUInteger gWAGRABIDMisses;

static void WAGRABEnsureResolverState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRABIDLock = [NSObject new];
        gWAGRABIDCache = [NSMutableDictionary dictionary];
    });
}

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
    // ADD (immediate), 32/64-bit. Current generated WAAB getters use the 64-bit
    // form to materialize an NSConstantString address from ADRP + ADD.
    if ((instruction & 0x7F000000u) != 0x11000000u) return NO;
    uint32_t rd = instruction & 0x1Fu;
    uint32_t rn = (instruction >> 5) & 0x1Fu;
    if (rd != wantedRegister || rn != wantedRegister) return NO;
    uintptr_t immediate = (instruction >> 10) & 0xFFFu;
    if ((instruction >> 22) & 1u) immediate <<= 12;
    if (outImmediate) *outImmediate = immediate;
    return YES;
}

static BOOL WAGRABAddressBelongsToImage(uintptr_t address,
                                        const Dl_info *implementationInfo) {
    if (!address || !implementationInfo || !implementationInfo->dli_fbase) return NO;
    Dl_info candidateInfo = {0};
    if (!dladdr((const void *)address, &candidateInfo) || !candidateInfo.dli_fbase) return NO;
    return candidateInfo.dli_fbase == implementationInfo->dli_fbase;
}

static NSString *WAGRABDecimalCStringAtAddress(uintptr_t address,
                                                const Dl_info *implementationInfo) {
    if (!WAGRABAddressBelongsToImage(address, implementationInfo)) return nil;
    const char *string = (const char *)address;
    size_t length = strnlen(string, 12);
    if (length == 0 || length >= 12) return nil;
    for (size_t index = 0; index < length; index++) {
        if (string[index] < '0' || string[index] > '9') return nil;
    }
    unsigned long long value = strtoull(string, NULL, 10);
    if (!value || value > 9999999999ULL) return nil;
    return [[NSString alloc] initWithBytes:string
                                    length:length
                                  encoding:NSASCIIStringEncoding];
}

static NSString *WAGRABDecimalConstantStringAtAddress(
    uintptr_t objectAddress,
    const Dl_info *implementationInfo) {

    // 64-bit NSConstantString/CFConstantString objects emitted in __cfstring use
    // the stable four-word layout:
    //   isa | flags/aux | const char *bytes | length
    // We deliberately do not message-send to the candidate object. Reading the
    // embedded bytes pointer keeps this decoder independent of Foundation class
    // initialization and avoids treating arbitrary data as an Objective-C id.
    if (!WAGRABAddressBelongsToImage(objectAddress, implementationInfo)) return nil;

    uintptr_t bytesAddress = 0;
    memcpy(&bytesAddress, (const void *)(objectAddress + 2 * sizeof(uintptr_t)),
           sizeof(bytesAddress));
    if (!bytesAddress) return nil;
    return WAGRABDecimalCStringAtAddress(bytesAddress, implementationInfo);
}

static NSString *WAGRABCandidateStableID(uintptr_t candidateAddress,
                                          const Dl_info *implementationInfo,
                                          BOOL *outWasConstantString) {
    if (outWasConstantString) *outWasConstantString = NO;

    NSString *direct = WAGRABDecimalCStringAtAddress(candidateAddress,
                                                      implementationInfo);
    if (direct.length) return direct;

    NSString *constant = WAGRABDecimalConstantStringAtAddress(candidateAddress,
                                                               implementationInfo);
    if (constant.length && outWasConstantString) *outWasConstantString = YES;
    return constant;
}

static NSString *WAGRABResolveFromMethod(Method method, BOOL *outWasConstantString) {
    if (outWasConstantString) *outWasConstantString = NO;
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    IMP implementation = method_getImplementation(method);
    if (!implementation) return nil;

    Dl_info info = {0};
    if (!dladdr((const void *)implementation, &info) || !info.dli_fbase) return nil;

    const uint32_t *words = (const uint32_t *)(const void *)implementation;
    uintptr_t basePC = (uintptr_t)(const void *)implementation;

    // Generated getters are tiny thunks. Twenty instructions leaves room for
    // compiler/PAC prologues while still keeping the search local to the getter.
    for (NSUInteger index = 0; index < 20; index++) {
        uintptr_t page = 0;
        uint32_t reg = 0;
        if (!WAGRABDecodeADRP(words[index], basePC + index * 4, &page, &reg)) continue;

        for (NSUInteger delta = 1; delta <= 6 && index + delta < 24; delta++) {
            uintptr_t addImmediate = 0;
            if (!WAGRABDecodeADDImmediate(words[index + delta], reg, &addImmediate)) continue;
            BOOL wasConstant = NO;
            NSString *candidate = WAGRABCandidateStableID(page + addImmediate,
                                                           &info,
                                                           &wasConstant);
            if (!candidate.length) continue;
            if (outWasConstantString) *outWasConstantString = wasConstant;
            return candidate;
        }
    }
    return nil;
}

NSString *WAGRABPropsStableIDForTarget(NSString *className,
                                        NSString *selectorName,
                                        BOOL classMethod) {
    if (!className.length || !selectorName.length) return nil;
    WAGRABEnsureResolverState();

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%c|%@",
                          className, classMethod ? '+' : '-', selectorName];
    @synchronized (gWAGRABIDLock) {
        id cached = gWAGRABIDCache[cacheKey];
        if (cached) return cached == NSNull.null ? nil : cached;
        gWAGRABIDAttempts++;
    }

    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod ? class_getClassMethod(cls, selector)
                                : class_getInstanceMethod(cls, selector);
    BOOL wasConstantString = NO;
    NSString *stableID = WAGRABResolveFromMethod(method, &wasConstantString);

    @synchronized (gWAGRABIDLock) {
        gWAGRABIDCache[cacheKey] = stableID ?: (id)NSNull.null;
        if (stableID.length) {
            if (wasConstantString) gWAGRABIDResolvedConstantString++;
            else gWAGRABIDResolvedDirectCString++;
        } else {
            gWAGRABIDMisses++;
        }
    }
    return stableID;
}

NSDictionary<NSString *, NSNumber *> *WAGRABPropsStableIDResolverStats(void) {
    WAGRABEnsureResolverState();
    @synchronized (gWAGRABIDLock) {
        return @{
            @"attempts" : @(gWAGRABIDAttempts),
            @"cache_entries" : @(gWAGRABIDCache.count),
            @"resolved" : @(gWAGRABIDResolvedDirectCString +
                             gWAGRABIDResolvedConstantString),
            @"resolved_direct_cstring" : @(gWAGRABIDResolvedDirectCString),
            @"resolved_cfconstantstring" : @(gWAGRABIDResolvedConstantString),
            @"misses" : @(gWAGRABIDMisses),
        };
    }
}

void WAGRABPropsStableIDResolverResetCache(void) {
    WAGRABEnsureResolverState();
    @synchronized (gWAGRABIDLock) {
        [gWAGRABIDCache removeAllObjects];
        gWAGRABIDAttempts = 0;
        gWAGRABIDResolvedDirectCString = 0;
        gWAGRABIDResolvedConstantString = 0;
        gWAGRABIDMisses = 0;
    }
}
