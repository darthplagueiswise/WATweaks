#import "WAGRWAABCentralOverride.h"
#import "WAGRABPropsStableIDResolver.h"
#import "WAGRRuntimeValueStore.h"
#import <objc/runtime.h>
#import <substrate.h>

static NSDictionary<NSString *, NSDictionary *> *gWAGRWAABCentralCache = nil;
static NSMutableArray<NSDictionary *> *gWAGRWAABCentralSnapshots = nil;
static NSObject *gWAGRWAABCentralRefreshLock = nil;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRWAABBoolOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRWAABIntegerOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRWAABDoubleOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gWAGRWAABStringOriginals = nil;
static dispatch_once_t gWAGRWAABCentralOnce;

static void WAGRWAABCentralEnsureStorage(void) {
    dispatch_once(&gWAGRWAABCentralOnce, ^{
        gWAGRWAABCentralRefreshLock = [NSObject new];
        gWAGRWAABCentralSnapshots = [NSMutableArray array];
        gWAGRWAABBoolOriginals = [NSMutableDictionary dictionary];
        gWAGRWAABIntegerOriginals = [NSMutableDictionary dictionary];
        gWAGRWAABDoubleOriginals = [NSMutableDictionary dictionary];
        gWAGRWAABStringOriginals = [NSMutableDictionary dictionary];
        gWAGRWAABCentralCache = @{};
    });
}

static BOOL WAGRWAABCentralStringIsDecimal(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return NO;
    return [value rangeOfCharacterFromSet:[NSCharacterSet.decimalDigitCharacterSet invertedSet]].location == NSNotFound;
}

static NSString *WAGRWAABCentralType(NSString *type) {
    if (!type.length) return @"";
    const char *cursor = type.UTF8String;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor ? [NSString stringWithFormat:@"%c", *cursor] : @"";
}

static BOOL WAGRWAABCentralIsDescriptorOverrideSpec(NSDictionary *spec,
                                                     NSString **outStableID,
                                                     NSString **outSelector,
                                                     id *outValue,
                                                     NSString **outType) {
    if (![spec isKindOfClass:NSDictionary.class]) return NO;
    NSString *className = spec[@"class"];
    NSString *selectorName = spec[@"selector"];
    BOOL meta = [spec[@"meta"] boolValue];
    NSString *type = WAGRWAABCentralType(spec[@"type"]);
    if (!className.length || !selectorName.length || !type.length) return NO;

    NSString *stableID = WAGRABPropsStableIDForTarget(className, selectorName, meta);
    if (!WAGRWAABCentralStringIsDecimal(stableID)) return NO;

    id value = WAGRRuntimeValueOverride(className, selectorName, meta);
    if (outStableID) *outStableID = stableID;
    if (outSelector) *outSelector = selectorName;
    if (outValue) *outValue = value ?: NSNull.null;
    if (outType) *outType = type;
    return YES;
}

void WAGRWAABCentralOverrideRefresh(void) {
    WAGRWAABCentralEnsureStorage();
    @synchronized (gWAGRWAABCentralRefreshLock) {
        NSMutableDictionary<NSString *, NSDictionary *> *next = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in WAGRRuntimeValueAllOverrideSpecs()) {
            NSString *stableID = nil;
            NSString *selectorName = nil;
            NSString *type = nil;
            id value = nil;
            if (!WAGRWAABCentralIsDescriptorOverrideSpec(spec, &stableID, &selectorName, &value, &type)) continue;
            NSDictionary *entry = @{ @"type": type,
                                     @"value": value ?: NSNull.null,
                                     @"selector": selectorName ?: @"" };
            next[stableID] = entry;
            if (selectorName.length) next[selectorName] = entry;
        }

        // Keep prior immutable snapshots alive. The central accessors are a hot,
        // multi-threaded path; this lets readers use a lock-free pointer lookup
        // while refreshes atomically replace the current immutable dictionary.
        NSDictionary *snapshot = [next copy];
        [gWAGRWAABCentralSnapshots addObject:snapshot];
        gWAGRWAABCentralCache = snapshot;
    }
}

static NSDictionary *WAGRWAABCentralEntryForKey(id key) {
    WAGRWAABCentralEnsureStorage();
    NSString *lookup = [key isKindOfClass:NSString.class] ? key : [key description];
    if (!lookup.length) return nil;
    NSDictionary *cache = gWAGRWAABCentralCache;
    return cache[lookup];
}

static NSString *WAGRWAABCentralHookID(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls) ?: @"", NSStringFromSelector(selector) ?: @""];
}

static IMP WAGRWAABCentralOriginalForReceiver(NSMutableDictionary<NSString *, NSValue *> *store,
                                               id receiver,
                                               SEL selector) {
    if (!receiver || !selector) return NULL;
    Class cls = object_getClass(receiver);
    if (class_isMetaClass(cls)) cls = (Class)receiver;
    else cls = [receiver class];
    while (cls) {
        NSValue *value = store[WAGRWAABCentralHookID(cls, selector)];
        if (value) return [value pointerValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

typedef BOOL      (*WAGRWAABBoolKeyIMP)(id, SEL, id, BOOL);
typedef long long (*WAGRWAABIntegerKeyIMP)(id, SEL, id, long long);
typedef double    (*WAGRWAABDoubleKeyIMP)(id, SEL, id, double);
typedef id        (*WAGRWAABStringKeyIMP)(id, SEL, id, id);

static BOOL WAGRWAABCentralBool(id self, SEL _cmd, id key, BOOL defaultValue) {
    WAGRWAABBoolKeyIMP original = (WAGRWAABBoolKeyIMP)WAGRWAABCentralOriginalForReceiver(gWAGRWAABBoolOriginals, self, _cmd);
    BOOL nativeValue = original ? original(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *entry = WAGRWAABCentralEntryForKey(key);
    if (!entry) return nativeValue;
    NSString *type = entry[@"type"];
    if (!([type isEqualToString:@"B"] || [type isEqualToString:@"c"])) return nativeValue;
    id value = entry[@"value"];
    return value == NSNull.null ? NO : [value boolValue];
}

static long long WAGRWAABCentralInteger(id self, SEL _cmd, id key, long long defaultValue) {
    WAGRWAABIntegerKeyIMP original = (WAGRWAABIntegerKeyIMP)WAGRWAABCentralOriginalForReceiver(gWAGRWAABIntegerOriginals, self, _cmd);
    long long nativeValue = original ? original(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *entry = WAGRWAABCentralEntryForKey(key);
    if (!entry) return nativeValue;
    NSString *type = entry[@"type"];
    if (![@[@"c", @"C", @"s", @"S", @"i", @"I", @"l", @"L", @"q", @"Q"] containsObject:type]) return nativeValue;
    id value = entry[@"value"];
    return value == NSNull.null ? 0LL : [value longLongValue];
}

static double WAGRWAABCentralDouble(id self, SEL _cmd, id key, double defaultValue) {
    WAGRWAABDoubleKeyIMP original = (WAGRWAABDoubleKeyIMP)WAGRWAABCentralOriginalForReceiver(gWAGRWAABDoubleOriginals, self, _cmd);
    double nativeValue = original ? original(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *entry = WAGRWAABCentralEntryForKey(key);
    if (!entry) return nativeValue;
    NSString *type = entry[@"type"];
    if (!([type isEqualToString:@"f"] || [type isEqualToString:@"d"])) return nativeValue;
    id value = entry[@"value"];
    return value == NSNull.null ? 0.0 : [value doubleValue];
}

static id WAGRWAABCentralString(id self, SEL _cmd, id key, id defaultValue) {
    WAGRWAABStringKeyIMP original = (WAGRWAABStringKeyIMP)WAGRWAABCentralOriginalForReceiver(gWAGRWAABStringOriginals, self, _cmd);
    id nativeValue = original ? original(self, _cmd, key, defaultValue) : defaultValue;
    NSDictionary *entry = WAGRWAABCentralEntryForKey(key);
    if (!entry || ![entry[@"type"] isEqualToString:@"@"]) return nativeValue;
    id value = entry[@"value"];
    return value == NSNull.null ? nil : value;
}

static BOOL WAGRWAABCentralClassOwnsSelector(Class cls, SEL selector) {
    if (!cls || !selector) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) { owns = YES; break; }
    }
    free(methods);
    return owns;
}

static BOOL WAGRWAABCentralInstallOne(Class cls,
                                      NSString *selectorName,
                                      IMP replacement,
                                      NSMutableDictionary<NSString *, NSValue *> *store) {
    if (!cls || !selectorName.length || !replacement || !store) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!WAGRWAABCentralClassOwnsSelector(cls, selector)) return NO;
    NSString *hookID = WAGRWAABCentralHookID(cls, selector);
    if (store[hookID]) return YES;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    IMP original = NULL;
    MSHookMessageEx(cls, selector, replacement, &original);
    if (!original || original == replacement) return NO;
    store[hookID] = [NSValue valueWithPointer:original];
    return YES;
}

static NSUInteger WAGRWAABCentralInstallAccessors(void) {
    WAGRWAABCentralEnsureStorage();
    NSUInteger installed = 0;
    for (NSString *className in @[ @"WAProperties", @"WAABProperties", @"WAABPropertiesPreChatd", @"FOAWAABPropertiesImpl", @"WAFoundation.FOAWAABPropertiesImpl" ]) {
        Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
        if (!cls) continue;
        if (WAGRWAABCentralInstallOne(cls, @"boolForKey:defaultValue:", (IMP)WAGRWAABCentralBool, gWAGRWAABBoolOriginals)) installed++;
        if (WAGRWAABCentralInstallOne(cls, @"integerForKey:defaultValue:", (IMP)WAGRWAABCentralInteger, gWAGRWAABIntegerOriginals)) installed++;
        if (WAGRWAABCentralInstallOne(cls, @"doubleForKey:defaultValue:", (IMP)WAGRWAABCentralDouble, gWAGRWAABDoubleOriginals)) installed++;
        if (WAGRWAABCentralInstallOne(cls, @"stringForKey:defaultValue:", (IMP)WAGRWAABCentralString, gWAGRWAABStringOriginals)) installed++;
    }
    return installed;
}

NSUInteger WAGRWAABCentralOverrideInstallPersisted(void) {
    WAGRWAABCentralOverrideRefresh();
    if (gWAGRWAABCentralCache.count == 0) return 0;
    return WAGRWAABCentralInstallAccessors();
}

BOOL WAGRWAABCentralOverrideInstallForTarget(NSString *className,
                                              NSString *selectorName,
                                              BOOL classMethod) {
    NSString *stableID = WAGRABPropsStableIDForTarget(className, selectorName, classMethod);
    if (!WAGRWAABCentralStringIsDecimal(stableID)) return NO;
    WAGRWAABCentralOverrideRefresh();
    if (!gWAGRWAABCentralCache[stableID]) return NO;
    (void)WAGRWAABCentralInstallAccessors();
    return gWAGRWAABCentralCache[stableID] != nil;
}
