#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WAGRFeatureStateSource) {
    WAGRFeatureStateSourceUnavailable = 0,
    WAGRFeatureStateSourceOriginal,
    WAGRFeatureStateSourceNativeCache,
    WAGRFeatureStateSourceOverride,
};

#ifdef __cplusplus
extern "C" {
#endif

NSDictionary *WAGRFeatureTarget(NSString *className, BOOL classMethod);
NSArray<NSDictionary *> *WAGRFeatureDefaultWAABTargets(void);

NSUInteger WAGRFeatureResolvedABID(NSString *selectorName, NSUInteger fallbackStableID);

BOOL WAGRFeatureReadBool(NSString *selectorName,
                         NSArray<NSDictionary *> * _Nullable targets,
                         NSUInteger fallbackStableID,
                         BOOL * _Nullable outValue,
                         WAGRFeatureStateSource * _Nullable outSource);

BOOL WAGRFeatureSetBool(NSString *selectorName,
                        NSArray<NSDictionary *> * _Nullable targets,
                        BOOL value);

void WAGRFeatureClearBool(NSString *selectorName,
                          NSArray<NSDictionary *> * _Nullable targets);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
