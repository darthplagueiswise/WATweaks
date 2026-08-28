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

/// Produces the portable JSON-ready v3 document from the native account cache.
/// Each numeric ABProp is enriched, when available, with the canonical getter
/// decoded from the current Mach-O and with WAMCEvaluation/MobileConfig metadata:
/// paramSpecifier, localConfigIndex, parameterIndex, compact parameter token,
/// stable ID returned by the live context manager, config name and parameter name.
/// Names are enrichment; the numeric translation remains available without an
/// id_name_mapping.json file when the current runtime exposes the embedded name
/// converter.
NSDictionary<NSString *, id> *WAGRABPropsNativeExportDocument(
    WAGRABPropsNativeSnapshot *snapshot);

NSString *WAGRABPropsNativeDiagnosticText(void);
NSString *WAGRABPropsDisplayNameForCode(NSString *code);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
