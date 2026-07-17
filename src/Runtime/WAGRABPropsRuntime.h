#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRABPropEntry : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *typeCode;
@property(nonatomic, copy) NSString *typeName;
@property(nonatomic, copy) NSString *categoryName;
@property(nonatomic, copy) NSString *sourceImage;
@property(nonatomic, copy) NSString *methodEncoding;
@property(nonatomic, assign) BOOL classMethod;
@property(nonatomic, assign) BOOL cataloged;
@end

#ifdef __cplusplus
extern "C" {
#endif

NSArray *WAGRABPropsResolveRuntimeObjects(id _Nullable userContext);
NSArray<WAGRABPropEntry *> *WAGRABPropsScan(NSArray *runtimeObjects);
id _Nullable WAGRABPropsReceiverForEntry(WAGRABPropEntry *entry,
                                          NSArray *runtimeObjects);
NSString *WAGRABPropsCurrentValue(WAGRABPropEntry *entry,
                                   NSArray *runtimeObjects,
                                   id _Nullable * _Nullable rawValue);
NSDictionary *WAGRABPropsCatalogStats(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
