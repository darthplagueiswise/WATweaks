#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Resolves WhatsApp's native AB Props controller/factory from the objects and
/// classes loaded in the current session. The expensive class enumeration is
/// performed only when the user explicitly opens AB Props.
UIViewController * _Nullable WAGRResolveNativeABPropsController(
    UIViewController *host,
    id _Nullable userContext,
    NSString * _Nullable * _Nullable diagnostic);

NSString *WAGRNativeABPropsResolverDiagnosticText(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
