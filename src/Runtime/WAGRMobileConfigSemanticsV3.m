#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>

#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

// Semantics proven against the supplied SharedModules build and the live crosswalk:
//
//   WAMCEvaluation(waStableId) -> paramSpecifier
//   getStableIdFromParamSpecifier(paramSpecifier) -> CONFIG stable ID
//
// The returned value is the params_map block header / mc_overrides top-level ID.
// The low 16 bits of the translated specifier are a compact parameter token and
// are NOT the textual mc_overrides parameter index. For the normal ABProp domain
// in this build, parameterIndex is 0 and the config stable ID happens to equal
// the WA stable ID for 16,907 primary mappings. Do not generalize that equality
// beyond the validated build/domain.

@implementation WAGRMobileConfigMapping (SemanticsV3)
- (uint16_t)compactParameterToken { return self.parameterStableId; }
- (uint64_t)configStableId { return self.externalConfigStableId; }
@end

static NSDictionary<NSString *, id> *(*orig_WAGRMCV3DictionaryRepresentation)(WAGRMobileConfigMapping *, SEL) = NULL;

static NSDictionary<NSString *, id> *hook_WAGRMCV3DictionaryRepresentation(WAGRMobileConfigMapping *self, SEL _cmd) {
    NSDictionary *base = orig_WAGRMCV3DictionaryRepresentation
        ? orig_WAGRMCV3DictionaryRepresentation(self, _cmd) : @{};
    if (![base isKindOfClass:NSDictionary.class]) return base ?: @{};

    NSMutableDictionary *result = [base mutableCopy];

    // Correct public/export terminology. Keep no ambiguous legacy key in v3.
    id configStableId = result[@"config_stable_id"] ?: result[@"external_config_stable_id"];
    if (configStableId) result[@"config_stable_id"] = configStableId;
    [result removeObjectForKey:@"external_config_stable_id"];

    id compact = result[@"compact_parameter_token"] ?: result[@"parameter_stable_id"];
    if (compact) result[@"compact_parameter_token"] = compact;
    [result removeObjectForKey:@"parameter_stable_id"];

    result[@"mapping_semantics"] = @"config_stable_id + parameter_index identify mc_overrides; compact_parameter_token is translation metadata";
    return result;
}

static BOOL WAGRMCV3InstallObjectNoArgHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char raw[32] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    const char *cursor = raw;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    if (*cursor != '@') return NO;
    IMP current = method_getImplementation(method);
    if (!current || current == replacement) return current == replacement;
    if (original) *original = current;
    method_setImplementation(method, replacement);
    return method_getImplementation(method) == replacement;
}

static void WAGRMCV3RewriteCrosswalkObject(id object) {
    if (![object isKindOfClass:NSMutableDictionary.class]) return;
    NSMutableDictionary *document = (NSMutableDictionary *)object;
    NSMutableDictionary *scan = [document[@"scan"] isKindOfClass:NSDictionary.class]
        ? [document[@"scan"] mutableCopy] : nil;
    if (scan) {
        id resolved = scan[@"config_ids_resolved"] ?: scan[@"external_ids_resolved"];
        if (resolved) scan[@"config_ids_resolved"] = resolved;
        [scan removeObjectForKey:@"external_ids_resolved"];
        document[@"scan"] = scan;
    }
    document[@"format"] = @"WATweaks WhatsApp ABProp -> FBMobileConfig live crosswalk v3";
    document[@"semantics"] = @{
        @"config_stable_id": @"FBMobileConfig config stable ID; mc_overrides top-level identity",
        @"parameter_index": @"mc_overrides row prefix inside the config",
        @"compact_parameter_token": @"low-16 translation token; not the mc_overrides row index",
        @"names": @"optional descriptive enrichment; IDs/indexes remain authoritative"
    };
}

static void (*orig_WAGRMCV3ExportJSONObject)(id, SEL, id, NSString *, void (^)(void)) = NULL;
static void hook_WAGRMCV3ExportJSONObject(id self, SEL _cmd, id object, NSString *filename, void (^completion)(void)) {
    id rewritten = object;
    if ([object isKindOfClass:NSDictionary.class] && [filename containsString:@"crosswalk"]) {
        NSMutableDictionary *mutable = [object mutableCopy];
        WAGRMCV3RewriteCrosswalkObject(mutable);
        rewritten = mutable;
    }
    if (orig_WAGRMCV3ExportJSONObject) {
        orig_WAGRMCV3ExportJSONObject(self, _cmd, rewritten, filename, completion);
    }
}

static BOOL WAGRMCV3InstallExportHook(void) {
    Class cls = NSClassFromString(@"WAGRMobileConfigExportVC");
    SEL selector = NSSelectorFromString(@"exportJSONObject:filename:completion:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 5) return NO;
    IMP current = method_getImplementation(method);
    if (!current || current == (IMP)hook_WAGRMCV3ExportJSONObject) return current != NULL;
    orig_WAGRMCV3ExportJSONObject = (void (*)(id, SEL, id, NSString *, void (^)(void)))current;
    method_setImplementation(method, (IMP)hook_WAGRMCV3ExportJSONObject);
    return method_getImplementation(method) == (IMP)hook_WAGRMCV3ExportJSONObject;
}

__attribute__((constructor))
static void WAGRMobileConfigSemanticsV3Ctor(void) {
    @autoreleasepool {
        Class mappingClass = NSClassFromString(@"WAGRMobileConfigMapping");
        BOOL mappingInstalled = WAGRMCV3InstallObjectNoArgHook(
            mappingClass,
            @selector(dictionaryRepresentation),
            (IMP)hook_WAGRMCV3DictionaryRepresentation,
            (IMP *)&orig_WAGRMCV3DictionaryRepresentation);
        BOOL exportInstalled = WAGRMCV3InstallExportHook();
        WAGRLogAppendF(@"[MobileConfig][SemanticsV3] mapping=%@ export=%@",
                       mappingInstalled ? @"YES" : @"NO",
                       exportInstalled ? @"YES" : @"NO");
    }
}
