#import "WAGRABPropsNativeOverrideEngine.h"

static NSString * const kWAGRABTrackedIntentRegistryKey = @"watweak_native_abprops_override_registry_v3";

static NSObject *WAGRABTrackedIntentLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, id> *WAGRABTrackedIntentMutableRegistry(void) {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kWAGRABTrackedIntentRegistryKey];
    return [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

void WAGRABPropsNativeRememberTrackedOverride(NSString *waStableID, id value) {
    if (!waStableID.length || !value) return;
    @synchronized (WAGRABTrackedIntentLock()) {
        NSMutableDictionary *registry = WAGRABTrackedIntentMutableRegistry();
        registry[waStableID] = value;
        [[NSUserDefaults standardUserDefaults] setObject:registry forKey:kWAGRABTrackedIntentRegistryKey];
    }
}

void WAGRABPropsNativeForgetTrackedOverride(NSString *waStableID) {
    if (!waStableID.length) return;
    @synchronized (WAGRABTrackedIntentLock()) {
        NSMutableDictionary *registry = WAGRABTrackedIntentMutableRegistry();
        [registry removeObjectForKey:waStableID];
        [[NSUserDefaults standardUserDefaults] setObject:registry forKey:kWAGRABTrackedIntentRegistryKey];
    }
}

void WAGRABPropsNativeForgetAllTrackedOverrides(void) {
    @synchronized (WAGRABTrackedIntentLock()) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kWAGRABTrackedIntentRegistryKey];
    }
}
