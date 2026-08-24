#import "WAGRMobileConfigBridge.h"

@implementation WAGRMobileConfigMapping (WAGRCanonicalStableIDAccessors)

- (uint16_t)compactParameterToken {
    return self.parameterStableId;
}

- (uint64_t)stableIdFromParamSpecifier {
    return self.externalConfigStableId;
}

- (uint64_t)configStableId {
    return self.externalConfigStableId;
}

@end
