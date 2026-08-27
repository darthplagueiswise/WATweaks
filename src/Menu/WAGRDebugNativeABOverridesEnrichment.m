#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

#import "../Runtime/WAGRABPropsRuntime.h"

extern id WAGRCurrentUserContext(void);

static NSDictionary *(*orig_WAGRDebugBuildDiagnosticDocumentDeep)(id, SEL, BOOL) = NULL;

static const char *WAGRDebugABSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRDebugABMethodReturnsObject(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRDebugABSkipQualifiers(raw)[0] == '@';
}

static id WAGRDebugABCallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([target class], selector);
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !WAGRDebugABMethodReturnsObject(method)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WAGRDebugABInterestingSelector(NSString *selectorName) {
    NSString *lower = selectorName.lowercaseString ?: @"";
    if (!lower.length) return NO;
    for (NSString *token in @[@"abprop", @"abpropert", @"override", @"debug",
                               @"reset", @"store", @"pref", @"configoverride",
                               @"value", @"set", @"remove", @"clear"]) {
        if ([lower containsString:token]) return YES;
    }
    return NO;
}

static NSArray<NSDictionary *> *WAGRDebugABMethodInventory(Class cls, BOOL classMethods) {
    if (!cls) return @[];
    Class owner = classMethods ? object_getClass((id)cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    if (!methods) return @[];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *name = selector ? NSStringFromSelector(selector) : @"";
        if (!WAGRDebugABInterestingSelector(name)) continue;
        const char *encoding = method_getTypeEncoding(methods[i]);
        [rows addObject:@{
            @"selector": name ?: @"",
            @"encoding": encoding ? ([NSString stringWithUTF8String:encoding] ?: @"") : @"",
            @"class_method": @(classMethods),
        }];
        if (rows.count >= 512) break;
    }
    free(methods);
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"selector"] localizedCaseInsensitiveCompare:b[@"selector"]];
    }];
    return rows;
}

static NSDictionary *WAGRDebugABClassInventory(Class cls) {
    if (!cls) return @{ @"present": @NO };
    const char *image = class_getImageName(cls);
    return @{
        @"present": @YES,
        @"class": NSStringFromClass(cls) ?: @"?",
        @"superclass": class_getSuperclass(cls) ? (NSStringFromClass(class_getSuperclass(cls)) ?: @"?") : @"nil",
        @"image": image ? ([NSString stringWithUTF8String:image] ?: @"") : @"",
        @"instance_methods": WAGRDebugABMethodInventory(cls, NO),
        @"class_methods": WAGRDebugABMethodInventory(cls, YES),
    };
}

static NSDictionary *WAGRDebugABContainerShape(id value) {
    if (!value) return @{ @"available": @NO };
    NSMutableDictionary *result = [@{
        @"available": @YES,
        @"class": NSStringFromClass([value class]) ?: @"?",
    } mutableCopy];

    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        result[@"container"] = @"NSDictionary";
        result[@"count"] = @(dictionary.count);
        NSMutableArray *samples = [NSMutableArray array];
        NSUInteger emitted = 0;
        for (id key in dictionary) {
            id object = dictionary[key];
            [samples addObject:@{
                @"key_class": NSStringFromClass([key class]) ?: @"?",
                @"key": [key description] ?: @"",
                @"value_class": object ? (NSStringFromClass([object class]) ?: @"?") : @"nil",
            }];
            if (++emitted >= 32) break;
        }
        result[@"sample"] = samples;
    } else if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) {
        result[@"count"] = @([(id)value count]);
    }
    result[@"runtime_methods"] = WAGRDebugABMethodInventory([value class], NO);
    return result;
}

static void WAGRDebugABRecordObject(NSMutableDictionary *objects,
                                    NSString *name,
                                    id object) {
    if (!name.length || !object) return;
    objects[name] = @{
        @"class": NSStringFromClass([object class]) ?: @"?",
        @"shape": WAGRDebugABContainerShape(object),
        @"class_inventory": WAGRDebugABClassInventory([object class]),
    };
}

static NSDictionary *WAGRDebugNativeABOverridesDocument(void) {
    id context = WAGRCurrentUserContext();
    NSArray *runtimeObjects = WAGRABPropsResolveRuntimeObjects(context);
    NSMutableDictionary *objects = [NSMutableDictionary dictionary];
    NSMutableArray *receiverRows = [NSMutableArray array];

    // These accessor names are present in the supplied WhatsApp/SharedModules
    // binaries. They are observational probes only: this diagnostic never calls
    // a setter/reset/sync method while discovering the object graph.
    for (NSString *selectorName in @[@"debugABPropsOverrider", @"aBPropsPreferences",
                                      @"debugOverrideStore", @"debugPropOverrides",
                                      @"debugOverrides"]) {
        id value = WAGRDebugABCallObjectNoArg(context, selectorName);
        if (value) WAGRDebugABRecordObject(objects,
            [NSString stringWithFormat:@"context.%@", selectorName], value);
    }

    NSUInteger receiverIndex = 0;
    for (id receiver in runtimeObjects ?: @[]) {
        if (!receiver) continue;
        NSMutableDictionary *row = [@{
            @"index": @(receiverIndex++),
            @"class": NSStringFromClass([receiver class]) ?: @"?",
        } mutableCopy];
        BOOL useful = NO;
        for (NSString *selectorName in @[@"debugPropOverrides", @"debugOverrides",
                                          @"aBPropsPreferences", @"debugOverrideStore"]) {
            id value = WAGRDebugABCallObjectNoArg(receiver, selectorName);
            if (!value) continue;
            useful = YES;
            row[selectorName] = WAGRDebugABContainerShape(value);
            WAGRDebugABRecordObject(objects,
                [NSString stringWithFormat:@"receiver%lu.%@",
                 (unsigned long)receiverIndex - 1, selectorName], value);

            // One safe extra level is enough to expose the actual preference/store
            // implementation without traversing an arbitrary object graph.
            for (NSString *nestedSelector in @[@"debugOverrideStore", @"aBPropsPreferences",
                                                 @"debugPropOverrides", @"debugOverrides"]) {
                id nested = WAGRDebugABCallObjectNoArg(value, nestedSelector);
                if (nested) WAGRDebugABRecordObject(objects,
                    [NSString stringWithFormat:@"receiver%lu.%@.%@",
                     (unsigned long)receiverIndex - 1, selectorName, nestedSelector], nested);
            }
        }
        if (useful) {
            row[@"class_inventory"] = WAGRDebugABClassInventory([receiver class]);
            [receiverRows addObject:row];
        }
    }

    NSMutableDictionary *knownClasses = [NSMutableDictionary dictionary];
    for (NSString *className in @[@"ABPropsPreferences",
                                   @"WADebugABPropertiesOverridesQRCodeView",
                                   @"WAPBConfigOverrideValue",
                                   @"WAProperties",
                                   @"WAABProperties",
                                   @"XMPPConnectionABPropsRequestManager",
                                   @"WAMobileConfigABPropsOverridesSync"]) {
        Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
        knownClasses[className] = WAGRDebugABClassInventory(cls);
    }

    return @{
        @"binary_model": @{
            @"read_pipeline": @"WAProperties/WAABProperties read through WAPropertiesStore and the account-scoped ABProps cache; debug override accessors are probed separately and are not assumed functional.",
            @"server_pipeline": @"XMPPConnectionABPropsRequestManager requestFreshABProps:withCompletion: -> requestFreshABPropsWithGroupJID:deltaUpdate:completion: -> XMPP query/retry -> WAProperties updateWithProperties:/deltaUpdateWithNewProperties: -> WAPropertiesStore account-scoped gabp.o namespace.",
            @"native_mobileconfig_sync_static_evidence": @"In the supplied WhatsApp(5) arm64 executable, +[WAMobileConfigABPropsOverridesSync syncABPropsOverridesToMCWithUserContext:] branches to a mov x0,#0; ret stub, while +overriddenStableIdsWithUserContext: returns CoreFoundation ___NSArray0__struct (empty NSArray). -[WADebugViewController resetAllOverriddenABProps] is ret. Treat this scaffold as disabled in this build.",
            @"debug_overrides_initializer_static_evidence": @"In supplied SharedModules(5), WAProperties -initWithPropertiesStore:debugOverrides: does not preserve/consume x3 (debugOverrides) in its common initializer path; WAABProperties forwards into that path. Do not assume the initializer argument is an active writer in this production build.",
            @"runtime_probe_purpose": @"The names aBPropsPreferences/debugOverrideStore/debugPropOverrides are present in the binaries. The live diagnostic inventories any resolved objects so a separate Swift/debug implementation can be verified from the actual runtime without guessing or invoking mutators.",
        },
        @"context_class": context ? (NSStringFromClass([context class]) ?: @"?") : @"nil",
        @"runtime_receiver_count": @(runtimeObjects.count),
        @"receivers_with_native_override_accessors": receiverRows,
        @"resolved_objects": objects,
        @"known_classes": knownClasses,
        @"next_evidence_needed": @"Share this JSON if aBPropsPreferences/debugOverrideStore resolves. Method inventories/type encodings on those live objects determine whether this build has a separate ABI-safe native debug writer that is not exposed through the disabled WAMobileConfigABPropsOverridesSync scaffold.",
    };
}

static NSDictionary *WAGRDebugBuildDiagnosticDocumentDeepWithNativeAB(id self, SEL _cmd, BOOL deep) {
    NSDictionary *base = orig_WAGRDebugBuildDiagnosticDocumentDeep
        ? orig_WAGRDebugBuildDiagnosticDocumentDeep(self, _cmd, deep) : @{};
    NSMutableDictionary *document = [base mutableCopy] ?: [NSMutableDictionary dictionary];
    document[@"native_abprops_override_engine"] = WAGRDebugNativeABOverridesDocument();
    return document;
}

static void WAGRDebugNativeABOverridesInstall(void) {
    Class cls = NSClassFromString(@"WAGRDebugDiagnosticsVC");
    SEL selector = NSSelectorFromString(@"buildDiagnosticDocumentDeep:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (!current || current == (IMP)WAGRDebugBuildDiagnosticDocumentDeepWithNativeAB) return;
    orig_WAGRDebugBuildDiagnosticDocumentDeep =
        (NSDictionary *(*)(id, SEL, BOOL))current;
    method_setImplementation(method, (IMP)WAGRDebugBuildDiagnosticDocumentDeepWithNativeAB);
}

__attribute__((constructor))
static void WAGRDebugNativeABOverridesEnrichmentCtor(void) {
    @autoreleasepool {
        // Installing a method wrapper is constant-time. All class/method/object
        // discovery above executes only after the user requests a Debug report.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRDebugNativeABOverridesInstall(); });
    }
}
