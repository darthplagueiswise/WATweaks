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

/// Asks WhatsApp's already-loaded native ABProps sync/request machinery to
/// perform a refresh. The resolver only invokes ABI-validated zero-argument
/// methods or one-object-argument methods whose selector explicitly requests a
/// context/userContext. It never implements the WA protocol itself.
BOOL WAGRABPropsTriggerNativeFetch(id _Nullable userContext,
                                   NSString * _Nullable * _Nullable diagnostic);

/// Produces a portable JSON-ready document containing every property from the
/// live native cache, plus metadata and the ABProp -> MobileConfig paramSpecifier
/// translation exposed by WAMCEvaluation when available.
NSDictionary<NSString *, id> *WAGRABPropsNativeExportDocument(
    WAGRABPropsNativeSnapshot *snapshot);

NSString *WAGRABPropsNativeDiagnosticText(void);
NSString *WAGRABPropsDisplayNameForCode(NSString *code);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
