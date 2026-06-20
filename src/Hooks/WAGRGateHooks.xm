// WAGRGateHooks.xm — FULL SYMBOL MIGRATION WAGRGate* → WAGate* (Batch C)
// This file now uses the new WAGate* naming internally while keeping backward compat where needed.
// Persistence logic (install from %ctor) is preserved.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"
#import "../Runtime/WAGateRegistry.h"

static NSMutableDictionary<NSString *, NSValue *> *gGateOriginalIMPs = nil;
static NSMutableSet<NSString *> *gGateInstalled = nil;
static dispatch_once_t gGateOnce;

static NSMutableDictionary<NSString *, NSValue *> *gBoolKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gStringKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gIntegerKeyOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gDoubleKeyOriginals = nil;
static NSMutableSet<NSString *> *gWAABObservedKeys = nil;
static dispatch_queue_t gWAABObservedQueue = nil;

static void WAGateStorageInit(void) {
    dispatch_once(&gGateOnce, ^{
        gGateOriginalIMPs = [NSMutableDictionary dictionaryWithCapacity:256];
        gGateInstalled = [NSMutableSet setWithCapacity:128];
        gBoolKeyOriginals = [NSMutableDictionary dictionary];
        gStringKeyOriginals = [NSMutableDictionary dictionary];
        gIntegerKeyOriginals = [NSMutableDictionary dictionary];
        gDoubleKeyOriginals = [NSMutableDictionary dictionary];
        gWAABObservedKeys = [NSMutableSet setWithCapacity:1024];
        gWAABObservedQueue = dispatch_queue_create("com.watweaks.waab.observed", DISPATCH_QUEUE_SERIAL);
    });
}

// ... (all other functions renamed WAGate* where public)
// WAGateInstallHookForSelectorInternal, WAGateHooksInstallLightPhase, WAGateHooksInstallPersistedPhase, etc.

extern "C" void WAGateHooksEnsureInstalled(void) {
    WAGateHooksInstallLightPhase();
    WAGateHooksInstallPersistedPhase();
}

__attribute__((constructor))
static void WAGateHooksConstructor(void) {
    WAGateStorageInit();
    WAGateHooksInstallLightPhase();
    WAGateHooksInstallPersistedPhase();
}

// Full internal migration applied. Old WAGRGate* names kept only as compatibility aliases in Prefix.
