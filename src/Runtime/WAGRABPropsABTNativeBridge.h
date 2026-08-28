#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result callback for an explicit account-scoped ABProps ABT sync request.
/// The callback is delivered on the main queue after the native response handler
/// has run and the persisted WAPropertiesStore backing has been checked.
typedef void (^WAGRABPropsABTCompletion)(NSDictionary<NSString *, id> *result);

#ifdef __cplusplus
extern "C" {
#endif

/// Sends WhatsApp's exact native ABProps request through the live
/// XMPPConnectionABPropsRequestManager.
///
/// refreshIDBranch == NO: regular/hash branch (configHash)
/// refreshIDBranch == YES: refresh-id branch
///
/// No stanza, auth state, XMPP connection or request manager is fabricated.
/// Returning YES means dispatch through the exact
/// -requestFreshABProps:withCompletion: ABI succeeded. Network/parse/apply
/// outcome is reported asynchronously by `completion`.
BOOL WAGRABPropsABTTriggerFetch(id _Nullable userContext,
                                BOOL refreshIDBranch,
                                WAGRABPropsABTCompletion _Nullable completion,
                                NSString * _Nullable * _Nullable diagnostic);

/// JSON-safe state of the native ABT bridge: captured session manager, exact
/// hook ABIs, last request, decoded response handler arguments and post-apply
/// persisted-store confirmation.
NSDictionary<NSString *, id> *WAGRABPropsABTNativeBridgeDocument(void);
NSString *WAGRABPropsABTNativeBridgeDiagnosticText(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
