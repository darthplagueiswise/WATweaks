// WAABPropsObserver.xm
// Compatibility owner for WAAB diagnostics only.
//
// Important startup rule: WAGRGateHooks.xm is the only file allowed to hook
// boolForKey:defaultValue: / stringForKey:defaultValue:. Having this file hook
// the same WAAB methods creates chained trampolines on WhatsApp's hottest flag
// read path and slows launch noticeably.

#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"

#define WAGR_LOG_SIZE 300
static NSMutableArray<NSString *> *gWAABLog = nil;
static dispatch_queue_t gWAABQueue = nil;
static dispatch_once_t gWAABStorageOnce = 0;

extern "C" void WAGRGateHooksEnsureInstalled(void);

static void WAGRLogEnsure(void) {
    dispatch_once(&gWAABStorageOnce, ^{
        gWAABLog = [NSMutableArray arrayWithCapacity:WAGR_LOG_SIZE];
        gWAABQueue = dispatch_queue_create("com.wagr.waab", DISPATCH_QUEUE_SERIAL);
    });
}

static void WAGRLogAppend(NSString *e) {
    if (!e) return;
    WAGRLogEnsure();
    dispatch_async(gWAABQueue, ^{
        if (gWAABLog.count >= WAGR_LOG_SIZE) [gWAABLog removeObjectAtIndex:0];
        [gWAABLog addObject:e];
    });
}

extern "C" void WAGRWAABEnsureHooksInstalled(void) {
    // Delegate to the single universal WAAB owner. Do not install any local
    // WAAB hook here, otherwise every WhatsApp AB flag read pays two trampolines.
    WAGRGateHooksEnsureInstalled();
}

extern "C" NSString *WAGRABObsLog(void) {
    WAGRLogEnsure();
    __block NSArray *snap = nil;
    dispatch_sync(gWAABQueue, ^{ snap = [gWAABLog copy]; });
    return snap.count ? [snap componentsJoinedByString:@"\n"] : @"(WAAB observer compatibility: live logging is disabled; WAGRGateHooks owns the hot path)";
}

extern "C" void WAGRABObsClear(void) {
    WAGRLogEnsure();
    dispatch_async(gWAABQueue, ^{ [gWAABLog removeAllObjects]; });
}

extern "C" NSString *WAGRWAABDiagnosticText(void) {
    NSUInteger active = 0;
    for (NSString *k in [[NSUserDefaults standardUserDefaults] dictionaryRepresentation]) {
        if ([k hasPrefix:@"wagr.waab."] || [k hasPrefix:@"watweak_gate_"]) active++;
    }
    WAGRLogAppend([NSString stringWithFormat:@"diagnostic active override-like keys=%lu", (unsigned long)active]);
    return [NSString stringWithFormat:
        @"WAAB hot path owner=WAGRGateHooks\nlocal WAAB hooks=disabled\nactive override-like keys=%lu\nobserver=%@",
        (unsigned long)active,
        WAGRPref(kWAGRABPropsObserver) ? @"ON" : @"OFF"];
}

__attribute__((constructor))
static void WAGRABInit(void) {
    @autoreleasepool {
        // Constructor-safe: allocate diagnostics only. No WAAB method hooks here.
        WAGRLogEnsure();
    }
}
