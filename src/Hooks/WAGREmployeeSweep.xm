// WAGREmployeeSweep.xm
// Runtime employee/internal discovery for WhatsApp.
//
// Rules:
// - never performs a global class scan from a constructor;
// - only accepts exact allowlisted selectors with zero explicit arguments;
// - only accepts BOOL/signed-char returns;
// - checks the force override before calling the original IMP;
// - persists exact targets and reinstalls only those targets on later launches;
// - disabling the toggle removes only entries created by this sweep.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>
#include <stdlib.h>
#import "../WAGramPrefix.h"

static NSString * const kWAGREmployeeSweepSource = @"waEmployeeSweep";

typedef BOOL (*WAGRBoolGetterIMP)(id, SEL);

typedef struct {
    SEL selector;
    IMP original;
    CFStringRef key;
} WAGREmployeeSweepDescriptor;

static NSMutableSet<NSString *> *gWAGREmployeeSweepInstalledKeys = nil;
static NSMutableDictionary<NSString *, NSValue *> *gWAGREmployeeSweepDescriptors = nil;
static NSObject *gWAGREmployeeSweepLock = nil;

static void WAGREmployeeSweepEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGREmployeeSweepInstalledKeys = [NSMutableSet set];
        gWAGREmployeeSweepDescriptors = [NSMutableDictionary dictionary];
        gWAGREmployeeSweepLock = [NSObject new];
    });
}

static NSSet<NSString *> *WAGREmployeeSweepSelectorAllowlist(void) {
    static NSSet<NSString *> *selectors = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selectors = [NSSet setWithArray:@[
            @"isInternalUser",
            @"isMetaEmployeeOrInternalTester",
            @"is_meta_employee_or_internal_tester",
            @"is_internal_tester",
            @"isEmployee",
            @"isViewerEmployee",
        ]];
    });
    return selectors;
}

static NSString *WAGREmployeeSweepKey(NSString *className,
                                      NSString *selectorName,
                                      BOOL classMethod) {
    return [NSString stringWithFormat:@"%@%@#%@",
            classMethod ? @"+" : @"",
            className ?: @"",
            selectorName ?: @""];
}

static NSDictionary<NSString *, NSDictionary *> *WAGREmployeeSweepOverridesSnapshot(void) {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:WA_PREF_EMPLOYEE_SWEEP_OVERRIDES];
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    return [raw copy];
}

static void WAGREmployeeSweepSaveOverrides(NSDictionary *overrides) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:overrides ?: @{} forKey:WA_PREF_EMPLOYEE_SWEEP_OVERRIDES];
    [defaults synchronize];
}

static BOOL WAGREmployeeSweepForcedValue(NSString *key, BOOL *hasOverride) {
    if (hasOverride) *hasOverride = NO;
    if (!key.length || !WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP)) return NO;

    NSDictionary *entry = WAGREmployeeSweepOverridesSnapshot()[key];
    if (![entry isKindOfClass:NSDictionary.class]) return NO;
    if (![entry[@"source"] isEqual:kWAGREmployeeSweepSource]) return NO;

    id force = entry[@"force"];
    if (![force respondsToSelector:@selector(boolValue)]) return NO;
    if (hasOverride) *hasOverride = YES;
    return [force boolValue];
}

static BOOL WAGREmployeeSweepMethodHasSafeABI(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c';
}

static BOOL WAGREmployeeSweepImageAllowedForIMP(IMP implementation) {
    if (!implementation) return NO;
    Dl_info info = {0};
    if (dladdr((const void *)implementation, &info) == 0 || !info.dli_fname) return NO;

    NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
    NSString *last = path.lastPathComponent ?: @"";

    if ([last isEqualToString:@"WhatsApp"] ||
        [last isEqualToString:@"SharedModules"]) {
        return YES;
    }

    if ([path containsString:@"/System/Library/"] ||
        [path containsString:@"/usr/lib/"]) {
        return NO;
    }

    if (![path containsString:@"/Frameworks/"]) return NO;
    return [last hasPrefix:@"WA"] ||
           [last hasPrefix:@"FB"] ||
           [last hasPrefix:@"FOA"] ||
           [last containsString:@"WhatsApp"] ||
           [last containsString:@"Meta"];
}

static BOOL WAGREmployeeSweepInstallTarget(Class baseClass,
                                            BOOL classMethod,
                                            NSString *selectorName) {
    if (!baseClass || !selectorName.length) return NO;
    if (![WAGREmployeeSweepSelectorAllowlist() containsObject:selectorName]) return NO;

    NSString *className = NSStringFromClass(baseClass);
    NSString *key = WAGREmployeeSweepKey(className, selectorName, classMethod);

    WAGREmployeeSweepEnsureState();
    @synchronized (gWAGREmployeeSweepLock) {
        if ([gWAGREmployeeSweepInstalledKeys containsObject:key]) return YES;
    }

    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod
        ? class_getClassMethod(baseClass, selector)
        : class_getInstanceMethod(baseClass, selector);
    if (!WAGREmployeeSweepMethodHasSafeABI(method)) return NO;

    IMP current = method_getImplementation(method);
    if (!WAGREmployeeSweepImageAllowedForIMP(current)) return NO;

    Class targetClass = classMethod ? object_getClass(baseClass) : baseClass;
    if (!targetClass) return NO;

    WAGREmployeeSweepDescriptor *descriptor =
        (WAGREmployeeSweepDescriptor *)calloc(1, sizeof(WAGREmployeeSweepDescriptor));
    if (!descriptor) return NO;
    descriptor->selector = selector;
    descriptor->key = (CFStringRef)CFBridgingRetain(key);

    IMP replacement = imp_implementationWithBlock(^BOOL(id receiver) {
        NSString *overrideKey = (__bridge NSString *)descriptor->key;
        BOOL hasOverride = NO;
        BOOL forcedValue = WAGREmployeeSweepForcedValue(overrideKey, &hasOverride);
        if (hasOverride) return forcedValue;

        WAGRBoolGetterIMP original = (WAGRBoolGetterIMP)descriptor->original;
        return original ? original(receiver, descriptor->selector) : NO;
    });

    MSHookMessageEx(targetClass,
                    selector,
                    replacement,
                    &descriptor->original);

    if (!descriptor->original) {
        imp_removeBlock(replacement);
        if (descriptor->key) CFRelease(descriptor->key);
        free(descriptor);
        return NO;
    }

    @synchronized (gWAGREmployeeSweepLock) {
        [gWAGREmployeeSweepInstalledKeys addObject:key];
        gWAGREmployeeSweepDescriptors[key] = [NSValue valueWithPointer:descriptor];
    }
    return YES;
}

static NSUInteger WAGREmployeeSweepScanClassMethods(Class baseClass,
                                                     BOOL classMethods,
                                                     NSMutableDictionary *overrides,
                                                     NSUInteger remaining) {
    if (!baseClass || remaining == 0) return 0;

    Class owner = classMethods ? object_getClass(baseClass) : baseClass;
    if (!owner) return 0;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    NSUInteger installed = 0;

    for (unsigned int index = 0; index < count && installed < remaining; index++) {
        Method method = methods[index];
        SEL selector = method_getName(method);
        NSString *selectorName = NSStringFromSelector(selector);
        if (![WAGREmployeeSweepSelectorAllowlist() containsObject:selectorName]) continue;
        if (!WAGREmployeeSweepMethodHasSafeABI(method)) continue;
        if (!WAGREmployeeSweepImageAllowedForIMP(method_getImplementation(method))) continue;

        NSString *className = NSStringFromClass(baseClass);
        NSString *key = WAGREmployeeSweepKey(className, selectorName, classMethods);
        if (!WAGREmployeeSweepInstallTarget(baseClass, classMethods, selectorName)) continue;

        overrides[key] = @{
            @"class" : className ?: @"",
            @"selector" : selectorName ?: @"",
            @"classMethod" : @(classMethods),
            @"force" : @YES,
            @"source" : kWAGREmployeeSweepSource,
        };
        installed++;
    }

    free(methods);
    return installed;
}

extern "C" NSUInteger WAGREmployeeSweepInstallNow(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:WA_PREF_EMPLOYEE_SWEEP];
    [defaults synchronize];

    NSMutableDictionary *overrides = [WAGREmployeeSweepOverridesSnapshot() mutableCopy];
    const NSUInteger limit = 160;
    NSUInteger installed = 0;

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return 0;

    __unsafe_unretained Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return 0;
    classCount = objc_getClassList(classes, classCount);

    for (int index = 0; index < classCount && installed < limit; index++) {
        Class cls = classes[index];
        if (!cls) continue;

        installed += WAGREmployeeSweepScanClassMethods(
            cls, NO, overrides, limit - installed);
        if (installed >= limit) break;
        installed += WAGREmployeeSweepScanClassMethods(
            cls, YES, overrides, limit - installed);
    }

    free(classes);
    WAGREmployeeSweepSaveOverrides(overrides);
    return installed;
}

extern "C" NSUInteger WAGREmployeeSweepDisable(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:NO forKey:WA_PREF_EMPLOYEE_SWEEP];

    NSDictionary *current = WAGREmployeeSweepOverridesSnapshot();
    NSMutableDictionary *kept = [NSMutableDictionary dictionaryWithCapacity:current.count];
    __block NSUInteger removed = 0;

    [current enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
        (void)stop;
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"source"] isEqual:kWAGREmployeeSweepSource]) {
            removed++;
        } else if (key) {
            kept[key] = entry ?: @{};
        }
    }];

    [defaults setObject:kept forKey:WA_PREF_EMPLOYEE_SWEEP_OVERRIDES];
    [defaults synchronize];
    return removed;
}

extern "C" NSUInteger WAGREmployeeSweepSetEnabled(BOOL enabled) {
    return enabled ? WAGREmployeeSweepInstallNow() : WAGREmployeeSweepDisable();
}

extern "C" NSUInteger WAGREmployeeSweepEnsureInstalled(void) {
    if (!WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP)) return 0;

    NSDictionary *overrides = WAGREmployeeSweepOverridesSnapshot();
    __block NSUInteger installed = 0;

    [overrides enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
        (void)key;
        (void)stop;
        if (![entry isKindOfClass:NSDictionary.class]) return;
        if (![entry[@"source"] isEqual:kWAGREmployeeSweepSource]) return;

        NSString *className = entry[@"class"];
        NSString *selectorName = entry[@"selector"];
        BOOL classMethod = [entry[@"classMethod"] boolValue];
        Class cls = className.length ? NSClassFromString(className) : Nil;
        if (WAGREmployeeSweepInstallTarget(cls, classMethod, selectorName)) installed++;
    }];

    return installed;
}

extern "C" NSString *WAGREmployeeSweepDiagnosticText(void) {
    WAGREmployeeSweepEnsureState();
    NSDictionary *overrides = WAGREmployeeSweepOverridesSnapshot();
    NSUInteger persisted = 0;
    for (NSDictionary *entry in overrides.allValues) {
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"source"] isEqual:kWAGREmployeeSweepSource]) {
            persisted++;
        }
    }

    NSUInteger installed = 0;
    @synchronized (gWAGREmployeeSweepLock) {
        installed = gWAGREmployeeSweepInstalledKeys.count;
    }

    return [NSString stringWithFormat:
            @"enabled=%@\npersisted=%lu\ninstalledThisProcess=%lu\nallowlist=%@",
            WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP) ? @"YES" : @"NO",
            (unsigned long)persisted,
            (unsigned long)installed,
            [[WAGREmployeeSweepSelectorAllowlist().allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]];
}

__attribute__((constructor))
static void WAGREmployeeSweepCtor(void) {
    @autoreleasepool {
        if (!WAPreferenceEnabled(WA_PREF_EMPLOYEE_SWEEP)) return;
        // Exact persisted reinstall only. No objc_getClassList/dladdr sweep here.
        WAGREmployeeSweepEnsureInstalled();
    }
}
