// WAGateRegistry.h — migrated from WAGRGateRegistry.h
// Gate provider registry (aggressive migration)

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGateProvider : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray<NSString *> *concreteClassNames;
@end

@interface WAGateRegistry : NSObject
+ (instancetype)shared;
+ (NSArray<WAGateProvider *> *)allProviders;
@end

NS_ASSUME_NONNULL_END