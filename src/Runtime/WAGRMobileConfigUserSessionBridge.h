#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Resolves only the account-scoped MobileConfig object actually attached to a
/// live WAProperties/WAABProperties instance. No sessionless/default manager is
/// accepted as a substitute.
id _Nullable WAGRMobileConfigLiveUserSessionManager(id _Nullable userContext);

/// Returns the last live UserSession manager captured by WAProperties.mc or
/// -setMobileConfig:. Does not perform a graph walk.
id _Nullable WAGRMobileConfigLiveCapturedUserSessionManager(void);

/// Runtime diagnostic intended for the in-app Debug exporter.
NSDictionary<NSString *, id> *WAGRMobileConfigLiveCaptureDiagnosticDocument(
    id _Nullable userContext);
NSString *WAGRMobileConfigLiveCaptureDiagnosticText(id _Nullable userContext);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
