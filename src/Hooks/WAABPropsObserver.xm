// WAABPropsObserver.xm
// Constructor-safe WAAB hook owner. Launch path installs only fixed selectors;
// no class list scan, no class_copyMethodList, no mass MSHookMessageEx.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../WAGramPrefix.h"

#define WAGR_LOG_SIZE 300
static NSMutableArray<NSString *> *gWAABLog = nil;
static dispatch_queue_t gWAABQueue = nil;
static dispatch_once_t gWAABStorageOnce = 0;
static NSMutableDictionary<NSString *, NSValue *> *gBoolKeyOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gStringKeyOrig = nil;
static NSUInteger gWAABHookedCount = 0;

typedef BOOL (*WAGRBoolKeyIMP)(id, SEL, NSString *, BOOL);
typedef id   (*WAGRStringKeyIMP)(id, SEL, NSString *, id);

static void WAGRLogEnsure(void) {
    dispatch_once(&gWAABStorageOnce, ^{
        gWAABLog = [NSMutableArray arrayWithCapacity:WAGR_LOG_SIZE];
        gWAABQueue = dispatch_queue_create("com.wagr.waab", DISPATCH_QUEUE_SERIAL);
        gBoolKeyOrig = [NSMutableDictionary dictionary];
        gStringKeyOrig = [NSMutableDictionary dictionary];
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

static NSString *WAGRWAABOverrideString(NSString *key) {
    if (!key.length) return nil;
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:WAGRKey(key)];
    if (stored.length) return stored;
    id legacy = [[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"wagr.override|waab|WAABProperties|inst|%@", key]];
    if (legacy) return [legacy boolValue] ? @"on" : @"off";
    return nil;
}

static BOOL WAGRBoolForKeyHook(id self, SEL _cmd, NSString *key, BOOL defaultVal) {
    NSString *className = NSStringFromClass([self class]) ?: @"";
    WAGRBoolKeyIMP orig = NULL;
    NSValue *v = gBoolKeyOrig[className];
    if (v) orig = (WAGRBoolKeyIMP)[v pointerValue];
    BOOL original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (!key.length) return original;

    NSString *stored = WAGRWAABOverrideString(key);
    if ([stored isEqualToString:@"on"]) {
        WAGRLogAppend([NSString stringWithFormat:@"[OVERRIDE/boolKey] %@ → YES", key]);
        return YES;
    }
    if ([stored isEqualToString:@"off"]) {
        WAGRLogAppend([NSString stringWithFormat:@"[OVERRIDE/boolKey] %@ → NO", key]);
        return NO;
    }
    if (WAGRPref(kWAGRABPropsObserver)) {
        WAGRLogAppend([NSString stringWithFormat:@"[obs/boolKey] %@ → %@", key, original ? @"YES" : @"NO"]);
    }
    return original;
}

static id WAGRStringForKeyHook(id self, SEL _cmd, NSString *key, id defaultVal) {
    NSString *className = NSStringFromClass([self class]) ?: @"";
    WAGRStringKeyIMP orig = NULL;
    NSValue *v = gStringKeyOrig[className];
    if (v) orig = (WAGRStringKeyIMP)[v pointerValue];
    id original = orig ? orig(self, _cmd, key, defaultVal) : defaultVal;
    if (!key.length) return original;

    NSString *stored = WAGRWAABOverrideString(key);
    if ([stored isEqualToString:@"on"]) return @"enabled";
    if ([stored isEqualToString:@"off"]) return @"";
    return original;
}

static void WAGRHookWAABFixedSelectors(Class cls) {
    if (!cls) return;
    WAGRLogEnsure();
    NSString *className = NSStringFromClass(cls) ?: @"";

    SEL boolSel = NSSelectorFromString(@"boolForKey:defaultValue:");
    if (!gBoolKeyOrig[className] && class_getInstanceMethod(cls, boolSel)) {
        IMP orig = NULL;
        MSHookMessageEx(cls, boolSel, (IMP)WAGRBoolForKeyHook, &orig);
        if (orig) { gBoolKeyOrig[className] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)]; gWAABHookedCount++; }
    }

    SEL stringSel = NSSelectorFromString(@"stringForKey:defaultValue:");
    if (!gStringKeyOrig[className] && class_getInstanceMethod(cls, stringSel)) {
        IMP orig = NULL;
        MSHookMessageEx(cls, stringSel, (IMP)WAGRStringForKeyHook, &orig);
        if (orig) { gStringKeyOrig[className] = [NSValue valueWithPointer:reinterpret_cast<const void *>(orig)]; gWAABHookedCount++; }
    }
}

extern "C" void WAGRWAABEnsureHooksInstalled(void) {
    WAGRHookWAABFixedSelectors(NSClassFromString(@"WAABProperties"));
    WAGRHookWAABFixedSelectors(NSClassFromString(@"FOAWAABPropertiesImpl"));
}

extern "C" NSString *WAGRABObsLog(void) {
    WAGRLogEnsure();
    __block NSArray *snap = nil;
    dispatch_sync(gWAABQueue, ^{ snap = [gWAABLog copy]; });
    return snap.count ? [snap componentsJoinedByString:@"\n"] : @"(sem observações ainda)";
}

extern "C" void WAGRABObsClear(void) {
    WAGRLogEnsure();
    dispatch_async(gWAABQueue, ^{ [gWAABLog removeAllObjects]; });
}

extern "C" NSString *WAGRWAABDiagnosticText(void) {
    WAGRLogEnsure();
    NSUInteger active = 0;
    for (NSString *k in [[NSUserDefaults standardUserDefaults] dictionaryRepresentation]) {
        if ([k hasPrefix:@"wagr.waab."]) active++;
    }
    return [NSString stringWithFormat:
        @"fixed selector hooks=%lu\nboolForKey classes=%lu\nstringForKey classes=%lu\nactive overrides=%lu\nobserver=%@",
        (unsigned long)gWAABHookedCount,
        (unsigned long)gBoolKeyOrig.count,
        (unsigned long)gStringKeyOrig.count,
        (unsigned long)active,
        WAGRPref(kWAGRABPropsObserver) ? @"ON" : @"OFF"];
}

__attribute__((constructor))
static void WAGRABInit(void) {
    @autoreleasepool {
        WAGRLogEnsure();
        WAGRWAABEnsureHooksInstalled();
    }
}
