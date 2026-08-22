#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

static NSDictionary<NSString *, id> *(*orig_WAGRMCMappingDictionary)(WAGRMobileConfigMapping *, SEL) = NULL;

static NSDictionary<NSString *, id> *hook_WAGRMCMappingDictionary(WAGRMobileConfigMapping *self, SEL _cmd) {
    NSDictionary *base = orig_WAGRMCMappingDictionary ? orig_WAGRMCMappingDictionary(self, _cmd) : @{};
    if (![base isKindOfClass:NSDictionary.class]) return base ?: @{};
    NSMutableDictionary *result = [base mutableCopy];
    id compact = result[@"parameter_stable_id"];
    if (compact) {
        result[@"compact_parameter_token"] = compact;
        [result removeObjectForKey:@"parameter_stable_id"];
    }
    return result;
}

__attribute__((constructor))
static void WAGRMobileConfigSemanticV2Ctor(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"WAGRMobileConfigMapping");
        SEL selector = @selector(dictionaryRepresentation);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method || method_getNumberOfArguments(method) != 2) return;
        MSHookMessageEx(cls, selector,
                        (IMP)hook_WAGRMCMappingDictionary,
                        (IMP *)&orig_WAGRMCMappingDictionary);
        if (orig_WAGRMCMappingDictionary) {
            WAGRLogAppend(@"[MobileConfig][SemanticV2] compact_parameter_token export naming installed");
        }
    }
}
