#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// The 13 group identifiers/titles compiled into WhatsApp 26.33.
NSArray<NSDictionary<NSString *, NSString *> *> *WAGRABPropsNativePresetGroups(void);

/// Resolves the group through WADeepLinkParser and hands it to the app's
/// WAABPropDeepLink consumer. This function never writes selector/value pairs.
BOOL WAGRABPropsRunNativePreset(UIViewController *rootViewController,
                                id userContext,
                                NSString *groupName,
                                NSString * _Nullable * _Nullable diagnostic);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
