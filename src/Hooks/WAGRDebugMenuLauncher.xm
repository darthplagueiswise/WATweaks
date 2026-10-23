// WhatsApp 26.40.10 dogfood launcher and account-identity diagnostics.
// Native evidence for this build exposes the Settings nudge URL below; it does
// not expose an instantiable private developer controller. Eligibility remains
// owned by server/account state and is never manufactured by this launcher.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Runtime/WAGRLog.h"

extern "C" void WAGRContextSpyInstallForContext(id ctx);

static id gWAGRLastUserContext = nil;
static NSString *gWAGRLastUserContextSource = nil;

extern "C" void WAGRRememberUserContext(id ctx, NSString *source) {
    if (!ctx) return;
    NSString *className = NSStringFromClass([ctx class]) ?: @"";
    if (![className containsString:@"Context"] &&
        ![className containsString:@"User"] &&
        ![className containsString:@"WA"]) return;
    gWAGRLastUserContext = ctx;
    gWAGRLastUserContextSource = [source copy] ?: @"unknown";
    WAGRLogAppendF(@"[UserContext] cached %@ from %@", className, gWAGRLastUserContextSource);
    WAGRContextSpyInstallForContext(ctx);
}

extern "C" id WAGRCurrentUserContext(void) {
    return gWAGRLastUserContext;
}

extern "C" NSString *WAGRCurrentUserContextDiagnostic(void) {
    return [NSString stringWithFormat:@"cached=%@\nsource=%@",
            gWAGRLastUserContext ? NSStringFromClass([gWAGRLastUserContext class]) : @"nil",
            gWAGRLastUserContextSource ?: @"none"];
}

static id WAGRLauncherObject(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char result[8] = {0};
    method_getReturnType(method, result, sizeof(result));
    if (result[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSString *WAGRLauncherBool(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return @"unavailable";
    Method method = class_getInstanceMethod([object class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return @"ABI mismatch";
    char result[8] = {0};
    method_getReturnType(method, result, sizeof(result));
    if (result[0] != 'B' && result[0] != 'c') return @"ABI mismatch";
    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
        return value ? @"YES" : @"NO";
    } @catch (__unused NSException *exception) {
        return @"exception";
    }
}

static BOOL WAGROpenDogfoodURL(NSError **outError) {
    NSURL *url = [NSURL URLWithString:@"https://fburl.com/df_iphone"];
    UIApplication *application = UIApplication.sharedApplication;
    if (!url || !application || ![application canOpenURL:url]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"WATweaks.Dogfood" code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    @"O entrypoint dogfood desta build não pôde ser aberto."}];
        }
        return NO;
    }
    [application openURL:url options:@{} completionHandler:^(BOOL success) {
        WAGRLogAppendF(@"[Dogfood] settings URL completion=%@", success ? @"YES" : @"NO");
    }];
    WAGRLogAppend(@"[Dogfood] dispatched verified Settings URL");
    return YES;
}

extern "C" BOOL WAGRLaunchNativeDeveloperMenu(__unused UIViewController *fromVC,
                                                NSError **outError) {
    return WAGROpenDogfoodURL(outError);
}

extern "C" BOOL WAGRLaunchPrivateExperimentationDebug(__unused UIViewController *fromVC,
                                                        NSError **outError) {
    if (outError) {
        *outError = [NSError errorWithDomain:@"WATweaks.Dogfood" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                @"Esta build não contém uma tela privada instanciável. Use o launcher dogfood verificado."}];
    }
    return NO;
}

extern "C" NSString *WAGRDebugMenuLauncherDiagnosticText(void) {
    id context = WAGRCurrentUserContext();
    id serverProperties = WAGRLauncherObject(context, @"serverProperties");
    if (!serverProperties) serverProperties = WAGRLauncherObject(context, @"abProperties");
    return [NSString stringWithFormat:
            @"entrypoint=https://fburl.com/df_iphone\n"
             "nativePrivateController=absent in supplied build\n"
             "eligibility=server/account-owned (read-only)\n"
             "isInternalUser=%@\n"
             "serverPropsDisableExperimental=%@\n%@",
            WAGRLauncherBool(context, @"isInternalUser"),
            WAGRLauncherBool(serverProperties, @"serverPropsDisableExperimental"),
            WAGRCurrentUserContextDiagnostic()];
}
