#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRABPropEntry : NSObject
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *typeCode;
@property(nonatomic, copy) NSString *typeName;
@property(nonatomic, assign) BOOL classMethod;
@end

NSArray *WAGRABPropsResolveRuntimeObjects(id _Nullable userContext);
NSArray<WAGRABPropEntry *> *WAGRABPropsScan(NSArray *runtimeObjects);
id _Nullable WAGRABPropsReceiverForEntry(WAGRABPropEntry *entry,
                                         NSArray *runtimeObjects);
NSString *WAGRABPropsCurrentValue(WAGRABPropEntry *entry,
                                  NSArray *runtimeObjects,
                                  id _Nullable * _Nullable rawValue);

NS_ASSUME_NONNULL_END
