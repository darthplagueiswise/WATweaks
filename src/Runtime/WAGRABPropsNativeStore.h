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
@property(nonatomic, copy) NSString *sourceKind;
@property(nonatomic, copy, nullable) NSString *storeClassName;
@property(nonatomic, copy, nullable) NSString *storeNamespace;
@property(nonatomic, copy, nullable) NSString *storeGroupJID;
@property(nonatomic, assign) NSInteger storePropertiesType;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Diagnostic fallback only. It scans the suite without proving account
/// ownership and must never source a correlated result or the ABT browser.
WAGRABPropsNativeSnapshot * _Nullable WAGRABPropsReadNativeSnapshot(
    NSError * _Nullable * _Nullable outError);

/// Exact account store owned by the WAProperties instance in the request.
/// SharedModules proves _propertiesStore +0x8 and properties +0x60.
WAGRABPropsNativeSnapshot * _Nullable WAGRABPropsReadNativeSnapshotForProperties(
    id properties,
    NSError * _Nullable * _Nullable outError);

/// ABT-only export; performs no MobileConfig resolution.
NSDictionary<NSString *, id> *WAGRABPropsNativeABTOnlyExportDocument(
    WAGRABPropsNativeSnapshot *snapshot);

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
