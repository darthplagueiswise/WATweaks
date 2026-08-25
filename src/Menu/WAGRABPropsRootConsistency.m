#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../Runtime/WAGRRuntimeValueStore.h"

static void WAGRABRootRuntimeApply(id self, SEL _cmd) {
    (void)_cmd;
    NSArray *specs = WAGRRuntimeValueAllOverrideSpecs();
    NSUInteger installed = WAGRRuntimeValueReinstallPersistedHooks();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AB Props"
        message:[NSString stringWithFormat:@"RuntimeValueStore overrides: %lu\nHooks reinstalados agora: %lu\n\nEste é o mesmo storage usado por Conta/Runtime/Overrides e pelos submenus Employee, Aura e Liquid Glass.",
                 (unsigned long)specs.count, (unsigned long)installed]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

__attribute__((constructor))
static void WAGRABRootConsistencyCtor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class cls = NSClassFromString(@"WAGRABPropsRootVC");
            Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"applyOverrides")) : NULL;
            if (method) method_setImplementation(method, (IMP)WAGRABRootRuntimeApply);
        });
    }
}
