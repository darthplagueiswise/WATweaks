#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRABPropsNativeSnapshot : NSObject
@property(nonatomic, copy) NSString *suiteName;
@property(nonatomic, copy) NSString *payloadKey;
@property(nonatomic, copy, nullable) NSString *metadataKey;
@property(nonatomic, copy) NSDictionary<NSString *, id> *props;
@property(nonatomic, copy) NSDictionary<NSString *, id> *metadata;
@property(nonatomic, copy) NSDate *loadedAt;
@property(nonatomic, assign) NSUInteger numericPropCount;
@property(nonatomic, copy) NSString *fingerprint;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the account-scoped ABProps cache that WhatsApp itself persists in
/// group.net.whatsapp.WhatsApp.shared. The selected payload is the largest
/// numeric-key dictionary under a gabp.*p key; abp.pnonep is intentionally not
/// treated as the primary account snapshot.
WAGRABPropsNativeSnapshot * _Nullable WAGRABPropsReadNativeSnapshot(
    NSError * _Nullable * _Nullable outError);

/// Invokes WhatsApp's exact fresh-fetch entrypoint for the current build:
/// -[XMPPConnectionABPropsRequestManager requestFreshABProps:NO withCompletion:].
/// The runtime captures/resolves the real XMPPConnectionABPropsRequestManager,
/// validates the Objective-C ABI, and returns NO rather than invoking a
/// fetch/sync/refresh lookalike when that exact entrypoint cannot be resolved.
BOOL WAGRABPropsTriggerNativeFetch(id _Nullable userContext,
                                   NSString * _Nullable * _Nullable diagnostic);

/// Produces a portable JSON-ready v2 document containing every property from
/// the live native cache, canonical code->selector names when the native getter
/// descriptor is available, and ABProp -> MobileConfig translation data.
/// `compact_parameter_token` is the low-16 translation token; the external
/// config/admin stable ID is separately resolved through
/// FBMobileConfigContextManager.getStableIdFromParamSpecifier: when available.
NSDictionary<NSString *, id> *WAGRABPropsNativeExportDocument(
    WAGRABPropsNativeSnapshot *snapshot);

NSString *WAGRABPropsNativeDiagnosticText(void);
NSString *WAGRABPropsDisplayNameForCode(NSString *code);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
