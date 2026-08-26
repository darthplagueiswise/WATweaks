#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRMobileConfigMapping : NSObject
/// WhatsApp/ABProp stable ID passed to WAMCEvaluation.getMCSpecifierForStableId:.
@property(nonatomic, assign) NSUInteger waStableId;
@property(nonatomic, assign) uint64_t paramSpecifier;
@property(nonatomic, assign) uint16_t localConfigIndex;
@property(nonatomic, assign) uint16_t parameterIndex;

/// Low 16 bits of WAMCEvaluation's translated paramSpecifier.
/// Compact translation metadata only: not the mc_overrides parameter index and
/// not an external MobileConfig stable/admin/config ID.
@property(nonatomic, readonly) uint16_t compactParameterToken;

/// Direct result of -[FBMobileConfigUserSessionContextManager
/// getStableIdFromParamSpecifier:]. This is the external MobileConfig config/admin
/// identity used at the top level of mc_overrides; it must not be assumed equal
/// to waStableId and must never be derived from localConfigIndex/token fields.
@property(nonatomic, readonly) uint64_t stableIdFromParamSpecifier;

/// Canonical alias for stableIdFromParamSpecifier used by mc_overrides emitters.
@property(nonatomic, readonly) uint64_t configStableId;

/// Legacy internal storage names retained for source/ABI compatibility.
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

/// Returns the best valid context manager for generic path/diagnostic work,
/// preferring the account-scoped user-session manager.
id _Nullable WAGRMobileConfigContextManager(id _Nullable userContext);

/// Returns only FBMobileConfigUserSessionContextManager (or a subclass). The
/// ABProp -> external config-ID crosswalk requires this account-scoped manager;
/// sessionless/default managers are not accepted as proof for mc_overrides IDs.
id _Nullable WAGRMobileConfigUserSessionContextManager(id _Nullable userContext);

NSString * _Nullable WAGRMobileConfigOverridesPath(id _Nullable userContext);
NSString * _Nullable WAGRMobileConfigNamesPath(id _Nullable userContext);

/// Resolves the current-build WA stable-ID domain through:
/// WA stable ID -> WAMCEvaluation paramSpecifier -> account-scoped
/// FBMobileConfigUserSessionContextManager -> external config stable ID.
NSArray<WAGRMobileConfigMapping *> * _Nullable WAGRMobileConfigResolveAll(
    id _Nullable userContext,
    WAGRMobileConfigProgressBlock _Nullable progress,
    NSError * _Nullable * _Nullable outError);

id _Nullable WAGRMobileConfigCurrentValue(WAGRMobileConfigMapping *mapping,
                                           id _Nullable userContext);

NSDictionary<NSString *, id> *WAGRMobileConfigCrosswalkDocument(
    NSArray<WAGRMobileConfigMapping *> *mappings,
    id _Nullable userContext);

/// Emits the real FBMobileConfig override grammar:
/// "<external config stable id>:<config name>" ->
/// ["<parameter index>: <parameter name>: <typed value>", ...].
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