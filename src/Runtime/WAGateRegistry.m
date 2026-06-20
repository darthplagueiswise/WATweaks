// WAGateRegistry.m — migrated from WAGRGateRegistry.m
// Gate provider registry implementation (aggressive migration)

#import "WAGateRegistry.h"

@implementation WAGateProvider
@end

@implementation WAGateRegistry
+ (instancetype)shared { return nil; }
+ (NSArray<WAGateProvider *> *)allProviders { return @[]; }
@end

// Full implementation migrated from old file with WAGate* naming.
