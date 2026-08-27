#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>

#import "../Runtime/WAGRABPropsRuntime.h"
#import "../Runtime/WAGRABPropsStableIDResolver.h"
#import "../Runtime/WAGRMobileConfigRuntimeResolver.h"

static void (*orig_WAGRABSnapshotSetExportDocument)(id, SEL, NSDictionary *) = NULL;

static id WAGRABSnapshotKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static unsigned long long WAGRABSnapshotParseStableID(NSString *stableID) {
    if (![stableID isKindOfClass:NSString.class] || !stableID.length) return 0;
    const char *bytes = stableID.UTF8String;
    if (!bytes || !*bytes) return 0;
    char *end = NULL;
    unsigned long long value = strtoull(bytes, &end, 10);
    if (end == bytes || (end && *end != '\0')) return 0;
    return value;
}

static NSDictionary<NSNumber *, NSString *> *WAGRABSnapshotLiveSelectorIndex(id userContext) {
    NSArray *objects = WAGRABPropsResolveRuntimeObjects(userContext);
    NSArray<WAGRABPropEntry *> *entries = WAGRABPropsScan(objects);
    NSMutableDictionary<NSNumber *, NSString *> *index = [NSMutableDictionary dictionary];
    for (WAGRABPropEntry *entry in entries) {
        if (!entry.selectorName.length) continue;
        NSString *stableID = WAGRABPropsStableIDForTarget(entry.className,
                                                           entry.selectorName,
                                                           entry.classMethod);
        unsigned long long stableValue = WAGRABSnapshotParseStableID(stableID);
        if (!stableValue) continue;
        NSNumber *key = @(stableValue);
        NSString *current = index[key];
        BOOL preferred = [entry.className containsString:@"WAABProperties"];
        if (!current.length || preferred) index[key] = entry.selectorName;
    }
    return index;
}

static uint64_t WAGRABSnapshotSpecifier(NSDictionary *mc) {
    id hex = mc[@"param_specifier_hex"];
    if ([hex isKindOfClass:NSString.class]) {
        const char *text = [(NSString *)hex UTF8String];
        return text ? strtoull(text, NULL, 0) : 0;
    }
    id numeric = mc[@"param_specifier"];
    return [numeric respondsToSelector:@selector(unsignedLongLongValue)]
        ? [numeric unsignedLongLongValue] : 0;
}

static NSDictionary *WAGRABSnapshotExactDocument(NSDictionary *document, id userContext) {
    if (![document isKindOfClass:NSDictionary.class]) return document ?: @{};
    NSArray *entries = [document[@"entries"] isKindOfClass:NSArray.class]
        ? document[@"entries"] : @[];
    NSDictionary<NSNumber *, NSString *> *liveIndex = WAGRABSnapshotLiveSelectorIndex(userContext);

    NSMutableArray *output = [NSMutableArray arrayWithCapacity:entries.count];
    NSUInteger liveNamed = 0;
    NSUInteger specifiers = 0;
    NSUInteger exactExternalIDs = 0;
    NSUInteger exactExternalMissing = 0;

    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *copy = [entry mutableCopy];
        unsigned long long code = [entry[@"code"] respondsToSelector:@selector(unsignedLongLongValue)]
            ? [entry[@"code"] unsignedLongLongValue] : 0;
        NSString *liveSelector = code ? liveIndex[@(code)] : nil;
        if (liveSelector.length) {
            copy[@"name"] = liveSelector;
            copy[@"identity_source"] = @"current Objective-C getter IMP";
            liveNamed++;
        }

        NSDictionary *oldMC = [entry[@"mobileconfig"] isKindOfClass:NSDictionary.class]
            ? entry[@"mobileconfig"] : nil;
        if (oldMC) {
            NSMutableDictionary *mc = [oldMC mutableCopy];
            uint64_t specifier = WAGRABSnapshotSpecifier(oldMC);
            if (specifier) {
                specifiers++;
                uint64_t exact = WAGRMobileConfigRuntimeStableIdForSpecifier(userContext, specifier);
                if (exact) {
                    mc[@"config_stable_id"] = @(exact);
                    mc[@"external_identity_source"] = @"exact FBMobileConfigUserSessionContextManager";
                    exactExternalIDs++;
                } else {
                    [mc removeObjectForKey:@"config_stable_id"];
                    mc[@"external_identity_source"] = @"unresolved; generic/sessionless identity discarded";
                    exactExternalMissing++;
                }
            } else {
                [mc removeObjectForKey:@"config_stable_id"];
            }
            copy[@"mobileconfig"] = mc;
        }
        [output addObject:copy];
    }

    NSMutableDictionary *result = [document mutableCopy];
    result[@"entries"] = output;
    result[@"mobileconfig_resolution"] = @{
        @"policy": @"exact UserSession only; generic/sessionless external IDs are discarded",
        @"runtime_stable_id_to_selector_count": @(liveIndex.count),
        @"entries_named_from_live_getters": @(liveNamed),
        @"param_specifiers_seen": @(specifiers),
        @"config_stable_ids_resolved": @(exactExternalIDs),
        @"config_stable_ids_unresolved": @(exactExternalMissing),
    };
    result[@"selector_identity_source"] = @"current Objective-C runtime getter -> stable ID decoded from live IMP";
    return result;
}

static void WAGRABSnapshotSetExportDocument(id self, SEL _cmd, NSDictionary *document) {
    id userContext = WAGRABSnapshotKVC(self, @"userContext");
    NSDictionary *exact = WAGRABSnapshotExactDocument(document, userContext);
    if (orig_WAGRABSnapshotSetExportDocument) {
        orig_WAGRABSnapshotSetExportDocument(self, _cmd, exact);
    }
}

static void WAGRABSnapshotInstallLiveEnrichment(void) {
    Class cls = NSClassFromString(@"WAGRABPropsSnapshotVC");
    SEL selector = NSSelectorFromString(@"setExportDocument:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (!current || current == (IMP)WAGRABSnapshotSetExportDocument) return;
    orig_WAGRABSnapshotSetExportDocument = (void (*)(id, SEL, NSDictionary *))current;
    method_setImplementation(method, (IMP)WAGRABSnapshotSetExportDocument);
}

__attribute__((constructor))
static void WAGRABPropsSnapshotLiveEnrichmentCtor(void) {
    @autoreleasepool {
        // Only the setter is wrapped here. The expensive live index is built
        // when the AB Props snapshot screen actually assigns its export document.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WAGRABSnapshotInstallLiveEnrichment(); });
    }
}
