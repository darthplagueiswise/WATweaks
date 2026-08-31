#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Re-registers the controller class that is compiled out of WhatsApp RC
/// builds. The returned class is named WADebugABPropertiesTableViewController
/// and has the loaded WAStaticTableViewController class as its real superclass.
Class _Nullable WAGRInstallWADebugABPropertiesTableViewController(
    NSString * _Nullable * _Nullable diagnostic);

/// Creates the reconstructed native Developer controller with the exact
/// account-scoped WAContext and WAContext.abProperties receiver.
UIViewController * _Nullable WAGRCreateWADebugABPropertiesTableViewController(
    id userContext,
    id abProperties,
    NSString * _Nullable * _Nullable diagnostic);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
