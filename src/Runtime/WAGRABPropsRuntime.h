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
BOOL WAGRABPropEntryIsBoolean(WAGRABPropEntry *entry);
NSString *WAGRABPropsCurrentValue(WAGRABPropEntry *entry,
                                   NSArray *runtimeObjects,
                                   BOOL * _Nullable boolValue,
                                   BOOL * _Nullable boolKnown);

NS_ASSUME_NONNULL_END
