#import "WAGRNativeAccountState.h"
#import <objc/runtime.h>
#import <objc/message.h>

static id WAGRAccountObject(id target, NSString *name) {
    if (!target) return nil;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod([target class], selector);
    char type[16] = {0};
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSDictionary *WAGRAccountBool(id target, NSString *name, BOOL meta) {
    SEL selector = NSSelectorFromString(name);
    Method method = target ? (meta ? class_getClassMethod((Class)target, selector)
                                  : class_getInstanceMethod([target class], selector)) : NULL;
    char type[16] = {0};
    if (!method || method_getNumberOfArguments(method) != 2) {
        return @{ @"available": @NO, @"value": NSNull.null };
    }
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') {
        return @{ @"available": @NO, @"value": NSNull.null, @"reason": @"ABI mismatch" };
    }
    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
        return @{ @"available": @YES, @"value": @(value) };
    } @catch (__unused NSException *exception) {
        return @{ @"available": @NO, @"value": NSNull.null, @"reason": @"native getter exception" };
    }
}

NSDictionary<NSString *, id> *WAGRNativeAccountStateDocument(id context) {
    id properties = WAGRAccountObject(context, @"abProperties");
    Class server = NSClassFromString(@"WAServerProperties");
    return @{
        @"context_available": @(context != nil),
        @"properties_available": @(properties != nil),
        @"server_internal_user": WAGRAccountBool(server, @"isInternalUser", YES),
        @"account_adm": WAGRAccountBool(properties, @"adm", NO),
        @"employee_or_internal_tester": WAGRAccountBool(properties, @"isMetaEmployeeOrInternalTester", NO),
        @"log_upload_employee_or_internal_tester": WAGRAccountBool(properties, @"is_meta_employee_or_internal_tester", NO),
        @"server_props_disable_experimental": WAGRAccountBool(properties, @"serverPropsDisableExperimental", NO),
        @"identity_policy": @"Native values only; employee/internal is not synthesized from a local toggle",
        @"fetch_policy": @"Account state is evidence, not an extra WATweaks gate. The native FetchPlan/authenticated pipeline owns eligibility."
    };
}
