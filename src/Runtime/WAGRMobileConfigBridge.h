#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRMobileConfigMapping : NSObject
@property(nonatomic, assign) NSUInteger waStableId;
@property(nonatomic, assign) uint64_t paramSpecifier;
@property(nonatomic, assign) uint16_t localConfigIndex;
@property(nonatomic, assign) uint16_t parameterIndex;

/// Low 16 bits of WAMCEvaluation's translated paramSpecifier.
/// This is compact translation metadata; it is not the mc_overrides row index
/// and must not be relabelled as an independent stable ID.
@property(nonatomic, readonly) uint16_t compactParameterToken;

/// Direct result of -[FBMobileConfigContextManager getStableIdFromParamSpecifier:].
/// On the analyzed WhatsApp ABProp domain this round-trips to waStableId for
/// every non-zero result observed. Keep the raw method semantics explicit so we
/// do not infer an ID from localConfigIndex or compactParameterToken.
@property(nonatomic, readonly) uint64_t stableIdFromParamSpecifier;

/// Compatibility alias used by existing override/export code. It resolves to
/// the same value as stableIdFromParamSpecifier; it is never derived from
/// localConfigIndex.
@property(nonatomic, readonly) uint64_t configStableId;

/// Legacy storage/accessor names retained for ABI/source compatibility inside
/// the tweak. Canonical callers should use compactParameterToken,
/// stableIdFromParamSpecifier and configStableId.
@property(nonatomic, assign) uint16_t parameterStableId;
@property(nonatomic, assign) uint64_t externalConfigStableId;

@property(nonatomic, assign) uint8_t nativeType;
@property(nonatomic, copy, nullable) NSString *configName;
@property(nonatomic, copy, nullable) NSString *parameterName;
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;
@end

typedef void (^WAGRMobileConfigProgressBlock)(NSUInteger current,
                                               NSUInteger total,
                                               NSUInteger translated,
                                               NSUInteger resolved);

typedef NS_ENUM(NSInteger, WAGRMobileConfigOverrideExportMode) {
    WAGRMobileConfigOverrideExportModeCurrentSnapshot = 0,
    WAGRMobileConfigOverrideExportModeAllBooleansTrue = 1,
};

#ifdef __cplusplus
extern "C" {
#endif

/// Installs transparent capture hooks on FBMobileConfigContextManager. Hooks only
/// remember the live manager and always forward the original return value.
void WAGRMobileConfigEnsureCaptureHooksInstalled(void);

/// Returns the best live FBMobileConfigContextManager available for this session.
id _Nullable WAGRMobileConfigContextManager(id _Nullable userContext);

/// Runtime paths returned by WhatsApp's own context manager. These functions do
/// not guess a path when a live manager exposes getOverridesTablePath.
NSString * _Nullable WAGRMobileConfigOverridesPath(id _Nullable userContext);
NSString * _Nullable WAGRMobileConfigNamesPath(id _Nullable userContext);

/// Resolves the complete current-build WA stable-ID domain through
/// WAMCEvaluation -> FBMobileConfigContextManager. Work should be performed off
/// the main thread. Untranslated stable IDs are omitted.
NSArray<WAGRMobileConfigMapping *> * _Nullable WAGRMobileConfigResolveAll(
    id _Nullable userContext,
    WAGRMobileConfigProgressBlock _Nullable progress,
    NSError * _Nullable * _Nullable outError);

/// Reads the effective MobileConfig value using the native typed getter family.
id _Nullable WAGRMobileConfigCurrentValue(WAGRMobileConfigMapping *mapping,
                                           id _Nullable userContext);

NSDictionary<NSString *, id> *WAGRMobileConfigCrosswalkDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id _Nullable userContext);

/// Builds FBMobileConfig's override grammar from the stable ID returned by the
/// live manager plus parameterIndex. Names are optional enrichment and are not
/// required to prove the numeric crosswalk.
NSDictionary<NSString *, id> *WAGRMobileConfigOverrideDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id _Nullable userContext,
    WAGRMobileConfigOverrideExportMode mode,
    NSDictionary<NSString *, id> * _Nullable * _Nullable stats);

NSData * _Nullable WAGRMobileConfigJSONData(id object, NSError **outError);
NSString *WAGRMobileConfigDiagnosticText(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
